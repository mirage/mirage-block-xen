(*
 * Copyright (c) 2011 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2012 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf
open OS
open Blkproto

type ops = {
  read : Io_page.t -> int64 -> int -> int -> unit Lwt.t;
  write : Io_page.t -> int64 -> int -> int -> unit Lwt.t;
}

type t = {
  domid:  int;
  xg:     Gnttab.interface;
  xe:     Eventchn.handle;
  evtchn: Eventchn.t;
  ops :   ops;
  parse_req : Cstruct.t -> Req.t;
  wait:   Eventchn.t -> unit Lwt.t;
}

let process t ring slot =
  let open Req in
  let req = t.parse_req slot in
  let fn = match req.op with
    | Some Read -> t.ops.read
    | Some Write -> t.ops.write
    | _ -> failwith "Unhandled request type"
  in
  let (_,threads) = List.fold_left (fun (off,threads) seg ->
    let sector = Int64.add req.sector (Int64.of_int off) in
    let perm = match req.op with
      | Some Read -> Gnttab.RO 
      | Some Write -> Gnttab.RW
      | _ -> failwith "Unhandled request type" in
    (* XXX: peeking inside the cstruct again *)
    let grant = { Gnttab.domid = t.domid; ref = Gnttab.grant_table_index_of_int32 seg.gref } in
    let thread = match Gnttab.map t.xg grant perm with
      | None -> failwith "Failed to map reference"
      | Some mapping ->
        try_lwt
          let page = Gnttab.Local_mapping.to_buf mapping in
          fn page sector seg.first_sector seg.last_sector
        finally
          let (_: bool) = Gnttab.unmap_exn t.xg mapping in
          return () in
    let newoff = off + (seg.last_sector - seg.first_sector + 1) in
    (newoff,thread::threads)
  ) (0, []) (Array.to_list req.segs) in
  let _ = (* handle the work in a background thread *)
    lwt () = Lwt.join threads in
    let open Res in 
    let slot = Ring.Rpc.Back.(slot ring (next_res_id ring)) in
    write_response (req.id, {op=req.Req.op; st=Some OK}) slot;
    let notify = Ring.Rpc.Back.push_responses_and_check_notify ring in
    (* XXX: what is this:
      if more_to_do then Activations.wake t.evtchn; *)
    if notify 
	then Eventchn.notify t.xe t.evtchn;
    return ()
  in ()

(* Thread to poll for requests and generate responses *)
let service_thread wait t evtchn fn =
  let rec inner () =
    Ring.Rpc.Back.ack_requests t fn;
    lwt () = wait evtchn in
    inner () in
  inner ()

let init xg xe domid ring_ref evtchn_ref proto wait ops =
  let evtchn = Eventchn.bind_interdomain xe domid evtchn_ref in
  let parse_req, idx_size = match proto with
    | X86_64 -> Req.Proto_64.read_request, Req.Proto_64.total_size
    | X86_32 -> Req.Proto_32.read_request, Req.Proto_64.total_size
    | Native -> Req.Proto_64.read_request, Req.Proto_64.total_size
  in
  let grants = List.map (fun r -> { Gnttab.domid = domid; ref = r }) [ ring_ref ] in
  match Gnttab.mapv xg grants Gnttab.RW with
  | None ->
    failwith "Gnttab.mapv failed"
  | Some mapping ->
    let buf = Gnttab.Local_mapping.to_buf mapping in
    let ring = Ring.Rpc.of_buf ~buf:(Io_page.to_cstruct buf) ~idx_size ~name:"blkback" in
    let r = Ring.Rpc.Back.init ring in
    let t = { domid; xg; xe; evtchn; ops; wait; parse_req } in
    let th = service_thread wait r evtchn (process t r) in
    on_cancel th (fun () -> let (_: bool) = Gnttab.unmap_exn xg mapping in ());
    th
