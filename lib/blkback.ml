(*
 * Copyright (c) 2010-2011 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2012-14 Citrix Systems Inc
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

module type ACTIVATIONS = sig

(** Event channels handlers. *)

type event
(** identifies the an event notification received from xen *)

val program_start: event
(** represents an event which 'fired' when the program started *)

val after: Eventchn.t -> event -> event Lwt.t
(** [next channel event] blocks until the system receives an event
    newer than [event] on channel [channel]. If an event is received
    while we aren't looking then this will be remembered and the
    next call to [after] will immediately unblock. If the system
    is suspended and then resumed, all event channel bindings are invalidated
    and this function will fail with Generation.Invalid *)
end

open Lwt
open Printf
open Blkproto
open Gnt

type ops = {
  read : int64 -> Cstruct.t list -> unit Lwt.t;
  write : int64 -> Cstruct.t list -> unit Lwt.t;
}

type ('a, 'b) t = {
  domid:  int;
  xg:     Gnttab.interface;
  xe:     Eventchn.handle;
  evtchn: Eventchn.t;
  ring:   ('a, 'b) Ring.Rpc.Back.t;
  ops :   ops;
  parse_req : Cstruct.t -> Req.t;
  wait:   Eventchn.t -> unit Lwt.t;
}

let page_size = 4096

module Opt = struct
  let map f = function
    | None -> None
    | Some x -> Some (f x)
  let iter f = function
    | None -> ()
    | Some x -> f x
  let default d = function
    | None -> d
    | Some x -> x
end

let empty = Cstruct.create 0

module Request = struct
  type kind = Read | Write

  type request = {
    kind: kind;
    sector: int64;
    buffers: Cstruct.t list;
    slots: int list;
  }

  (* partition into parallel groups where everything within a group can
     be executed in parallel since all the conflicts are between groups. *)

end

module Make(A: ACTIVATIONS) = struct
let service_thread t =
  let rec loop_forever after =
    (* For all the requests on the ring, build up a list of
       writable and readonly grants. We will map and unmap these
       as a batch. *)
    let writable_grants = ref [] in
    let readonly_grants = ref [] in
    (* The grants for a request will end up in the middle of a
       mapped block, so we need to know at which page offset it
       starts. *)
    let requests = ref [] in (* request record * offset within block of pages *)
    let next_writable_idx = ref 0 in
    let next_readonly_idx = ref 0 in

    let grants_of_segments = List.map (fun seg  -> {
          Gnttab.domid = t.domid;
          ref = Int32.to_int seg.Req.gref;
        }) in

    let is_writable req = match req.Req.op with
      | Some Req.Read -> true (* we need to write into the page *) 
      | Some Req.Write -> false (* we read from the guest and write to the backend *)
      | _ -> failwith "Unhandled request type" in

    let maybe_mapv writable = function
      | [] -> None (* nothing to do *)
      | grants ->
        begin match Gnttab.mapv t.xg grants writable with
          | None -> failwith "Failed to map grants" (* TODO: handle this error cleanly *)
          | x -> x
        end in

    (* Prepare to map all grants on the ring: *)
    Ring.Rpc.Back.ack_requests t.ring
      (fun slot ->
         let open Req in
         let req = t.parse_req slot in
         let segs = Array.to_list req.segs in
         if is_writable req then begin
           let grants = grants_of_segments segs in
           writable_grants := !writable_grants @ grants;
           requests := (req, !next_writable_idx) :: !requests;
           next_writable_idx := !next_writable_idx + (List.length grants)
         end else begin
           let grants = grants_of_segments segs in
           readonly_grants := !readonly_grants @ grants;
           requests := (req, !next_readonly_idx) :: !requests;
           next_readonly_idx := !next_readonly_idx + (List.length grants)
         end;
      );
    (* -- at this point the ring slots may be overwritten *)
    let requests = List.rev !requests in
    (* Make one big writable mapping *)
    let writable_mapping = maybe_mapv true !writable_grants in
    let readonly_mapping = maybe_mapv false !readonly_grants in

    let writable_buffer = 
      Opt.(default empty (map (fun x -> Cstruct.of_bigarray (Gnttab.Local_mapping.to_buf x)) writable_mapping)) in
    let readonly_buffer =
      Opt.(default empty (map (fun x -> Cstruct.of_bigarray (Gnttab.Local_mapping.to_buf x)) readonly_mapping)) in

    let _ = (* perform everything else in a background thread *)
      let open Block_request in
      let requests = List.fold_left (fun acc (request, page_offset) -> match request.Req.op with
        | None -> printf "Unknown blkif request type\n%!"; failwith "unknown blkif request type";
        | Some op ->
          let buffer = if is_writable request then writable_buffer else readonly_buffer in
          let buffer = Cstruct.sub buffer (page_offset * page_size) (Array.length request.Req.segs * page_size) in
          let (_, bufs) = List.fold_left (fun (idx, bufs) seg ->
            let page = Cstruct.sub buffer (idx * page_size) page_size in
            let frag = Cstruct.sub page (seg.Req.first_sector * 512) ((seg.Req.last_sector - seg.Req.first_sector + 1) * 512) in
            idx + 1, frag :: bufs
          ) (0, []) (Array.to_list request.Req.segs) in
          add acc request.Req.id op request.Req.sector (List.rev bufs)
        ) empty requests in
      let rec work remaining = match pop remaining with
      | [], _ -> return ()
      | now, later ->
        lwt () = Lwt_list.iter_p (fun r ->
          lwt () = (if r.op = Req.Read then t.ops.read else t.ops.write) r.sector r.buffers in
          let open Res in
          List.iter (fun id ->
            let slot = Ring.Rpc.Back.(slot t.ring (next_res_id t.ring)) in
            (* These responses aren't visible until pushed (below) *)
            write_response (id, {op=Some r.Block_request.op; st=Some OK}) slot;
          ) r.id;
          return ()
        ) now in
        work later in
      lwt () = work requests in

      (* We must unmap before pushing because the frontend will attempt
         to reclaim the pages (without this you get "g.e. still in use!"
         errors from Linux *)
      let () = try
          Opt.iter (Gnttab.unmap_exn t.xg) readonly_mapping 
        with e -> printf "Failed to unmap: %s\n%!" (Printexc.to_string e) in
      let () = try Opt.iter (Gnttab.unmap_exn t.xg) writable_mapping 
        with e -> printf "Failed to unmap: %s\n%!" (Printexc.to_string e) in
      (* Make the responses visible to the frontend *)
      let notify = Ring.Rpc.Back.push_responses_and_check_notify t.ring in
      if notify then Eventchn.notify t.xe t.evtchn;
      return () in

    lwt next = A.after t.evtchn after in
    loop_forever next in
  loop_forever A.program_start

let init xg xe domid ring_info wait ops =
  let evtchn = Eventchn.bind_interdomain xe domid ring_info.RingInfo.event_channel in
  let parse_req, idx_size = match ring_info.RingInfo.protocol with
    | Protocol.X86_64 -> Req.Proto_64.read_request, Req.Proto_64.total_size
    | Protocol.X86_32 -> Req.Proto_32.read_request, Req.Proto_32.total_size
    | Protocol.Native -> Req.Proto_64.read_request, Req.Proto_64.total_size
  in
  let grants = List.map (fun r ->
      { Gnttab.domid = domid; ref = Int32.to_int r })
      [ ring_info.RingInfo.ref ] in
  match Gnttab.mapv xg grants true with
  | None ->
    failwith "Gnttab.mapv failed"
  | Some mapping ->
    let buf = Gnttab.Local_mapping.to_buf mapping in
    let ring = Ring.Rpc.of_buf ~buf:(Io_page.to_cstruct buf) ~idx_size ~name:"blkback" in
    let ring = Ring.Rpc.Back.init ring in
    let t = { domid; xg; xe; evtchn; ops; wait; parse_req; ring } in
    let th = service_thread t in
    on_cancel th (fun () -> let () = Gnttab.unmap_exn xg mapping in ());
    th
end
