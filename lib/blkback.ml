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
open Gnt

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

let page_size = 4096

let process t ring slot =
  let open Req in
  let req = t.parse_req slot in
  let fn = match req.op with
    | Some Read -> t.ops.read
    | Some Write -> t.ops.write
    | _ -> failwith "Unhandled request type"
  in
  let writable = match req.op with
    | Some Read -> true (* we need to write into the page *) 
    | Some Write -> false (* we read from the guest and write to the backend *)
    | _ -> failwith "Unhandled request type" in

  let segments = Array.to_list req.segs in
  let grants = List.map (fun seg -> { Gnttab.domid = t.domid; ref = Gnt.grant_table_index_of_int32 seg.gref }) segments in

  let mapping = match Gnttab.mapv t.xg grants writable with
    | Some x -> x
    | None -> failwith "Failed to map reference" in
  let buffer = Gnttab.Local_mapping.to_buf mapping in

  let (_, _, threads) = List.fold_left (fun (idx, off, threads) seg ->
    let page = Bigarray.Array1.sub buffer (idx * page_size) page_size in

    let sector = Int64.(add req.sector (of_int off)) in
    let th = fn page sector seg.first_sector seg.last_sector in
    let newoff = off + (seg.last_sector - seg.first_sector + 1) in

    idx + 1, newoff, th :: threads
  ) (0, 0, []) segments in

  let _ = (* handle the work in a background thread *)
    lwt () = Lwt.join threads in
    let () = try Gnttab.unmap_exn t.xg mapping with e -> printf "Failed to unmap: %s\n%!" (Printexc.to_string e) in
    let open Res in 
    let slot = Ring.Rpc.Back.(slot ring (next_res_id ring)) in
    write_response (req.id, {op=req.Req.op; st=Some OK}) slot;
    let notify = Ring.Rpc.Back.push_responses_and_check_notify ring in

    if notify then Eventchn.notify t.xe t.evtchn;
    return ()
  in ()

(* Thread to poll for requests and generate responses *)
let service_thread wait t evtchn fn =
  let rec inner () =
    Ring.Rpc.Back.ack_requests t fn;
    lwt () = wait evtchn in
    inner () in
  inner ()

let init xg xe domid ring_info wait ops =
  let evtchn = Eventchn.bind_interdomain xe domid ring_info.RingInfo.event_channel in
  let parse_req, idx_size = match ring_info.RingInfo.protocol with
    | Protocol.X86_64 -> Req.Proto_64.read_request, Req.Proto_64.total_size
    | Protocol.X86_32 -> Req.Proto_32.read_request, Req.Proto_32.total_size
    | Protocol.Native -> Req.Proto_64.read_request, Req.Proto_64.total_size
  in
  let grants = List.map (fun r ->
    { Gnttab.domid = domid; ref = Gnt.grant_table_index_of_int32 r })
    [ ring_info.RingInfo.ref ] in
  match Gnttab.mapv xg grants true with
  | None ->
    failwith "Gnttab.mapv failed"
  | Some mapping ->
    let buf = Gnttab.Local_mapping.to_buf mapping in
    let ring = Ring.Rpc.of_buf ~buf:(Io_page.to_cstruct buf) ~idx_size ~name:"blkback" in
    let r = Ring.Rpc.Back.init ring in
    let t = { domid; xg; xe; evtchn; ops; wait; parse_req } in
    let th = service_thread wait r evtchn (process t r) in
    on_cancel th (fun () -> let () = Gnttab.unmap_exn xg mapping in ());
    th
