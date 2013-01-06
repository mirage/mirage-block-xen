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
  xg:     Gnttab.handle;
  evtchn: Evtchn.t;
  ops :   ops;
  parse_req : Cstruct.t -> Req.t;
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
    let thread = Gnttab.with_mapping t.xg t.domid seg.gref perm
      (fun page -> fn page sector seg.first_sector seg.last_sector) in
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
	then Evtchn.notify t.evtchn;
    return ()
  in ()

(* Thread to poll for requests and generate responses *)
let service_thread t evtchn fn =
  let rec inner () =
    Ring.Rpc.Back.ack_requests t fn;
    lwt () = Activations.wait evtchn in
    inner () in
  inner ()

let init xg domid ring_ref evtchn_ref proto ops =
  let evtchn = Evtchn.bind_interdomain domid evtchn_ref in
  let parse_req, idx_size = match proto with
    | X86_64 -> Req.Proto_64.read_request, Req.Proto_64.total_size
    | X86_32 -> Req.Proto_32.read_request, Req.Proto_64.total_size
    | Native -> Req.Proto_64.read_request, Req.Proto_64.total_size
  in
  let buf = Gnttab.map_contiguous_grant_refs xg domid [ ring_ref ] Gnttab.RW in
  let ring = Ring.Rpc.of_buf ~buf:(Io_page.to_cstruct buf) ~idx_size ~name:"blkback" in
  let r = Ring.Rpc.Back.init ring in
  let t = { domid; xg; evtchn; ops; parse_req } in
  let th = service_thread r evtchn (process t r) in
  on_cancel th (fun () -> Gnttab.unmap xg buf);
  th
