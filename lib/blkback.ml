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

type stats = {
  ring_utilisation: int array; (* one entry per leval, last entry includes all larger levels *)
  segments_per_request: int array; (* one entry per number of segments *)
  mutable total_requests: int;
  mutable total_ok: int;
  mutable total_error: int;
}

type ('a, 'b) t = {
  domid:  int;
  xg:     Gnttab.interface;
  xe:     Eventchn.handle;
  evtchn: Eventchn.t;
  ring:   ('a, 'b) Ring.Rpc.Back.t;
  ops :   ops;
  parse_req : Cstruct.t -> Req.t;
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

module BlockError = struct
  open Lwt
  let (>>=) x f = x >>= function
  | `Ok x -> f x
  | `Error (`Unknown x) -> fail (Failure x)
  | `Error `Unimplemented -> fail (Failure "unimplemented in block device")
  | `Error `Is_read_only -> fail (Failure "block device is read-only")
  | `Error `Disconnected -> fail (Failure "block device is disconnected")
  | `Error _ -> fail (Failure "unknown block device failure")
end

let is_writable req = match req.Req.op with
| Some Req.Read -> true (* we need to write into the page *) 
| Some Req.Write -> false (* we read from the guest and write to the backend *)
| None ->
  printf "FATAL: unknown request type\n%!";
  failwith "unknown request type"
| Some op ->
  printf "FATAL: unhandled request type %s\n%!" (Req.string_of_op op);
  failwith "unhandled request type"

module Make(A: ACTIVATIONS)(X: Xs_client_lwt.S)(B: V1_LWT.BLOCK with type id := string) = struct
let service_thread t stats =

  let grants_of_segments = List.map (fun seg -> {
    Gnttab.domid = t.domid;
    ref = Int32.to_int seg.Req.gref;
  }) in

  let rec loop_forever after =
    (* For all the requests on the ring, build up a list of
       writable and readonly grants. We will map and unmap these
       as a batch. We need two batches: the first will include
       the indirect descriptors which must be mapped before we
       can form the second batch. *)

    (* a convenience table of grantref -> page Cstruct.t *)
    let grant_table = Hashtbl.create 16 in

    let lookup_mapping gref =
      if not(Hashtbl.mem grant_table gref) then begin
        printf "FATAL: failed to find mapped grant reference %ld\n%!" gref;
        failwith "failed to find mapped grant reference"
      end else Hashtbl.find grant_table gref in

    let maybe_mapv writable = function
      | [] -> None (* nothing to do *)
      | grants ->
        begin match Gnttab.mapv t.xg grants writable with
          | None ->
            printf "FATAL: failed to map batch of %d grant references\n%!" (List.length grants);
            failwith "Failed to map grants" (* TODO: handle this error cleanly *)
          | Some x ->
            let buf = Cstruct.of_bigarray (Gnttab.Local_mapping.to_buf x) in
            let _ = List.fold_left (fun i gref -> Hashtbl.add grant_table (Int32.of_int gref.Gnttab.ref) (Cstruct.sub buf (4096 * i) 4096); i + 1) 0 grants in
            Some x
        end in
    let maybe_unmap mapping =
      try
        Opt.iter (Gnttab.unmap_exn t.xg) mapping 
      with e ->
        printf "FATAL: failed to unmap grant references (frontend will be confused (%s)\n%!" (Printexc.to_string e) in

    (* Dequeue all requests on the ring. *)
    let q = ref [] in
    let counter = ref 0 in
    let indirect_grants = ref [] in
    Ring.Rpc.Back.ack_requests t.ring
      (fun slot ->
         incr counter;
         let open Req in
         let req = t.parse_req slot in
         q := req :: !q;
         match req.segs with
         | Indirect grefs ->
           let grefs = List.map (fun g -> { Gnttab.domid = t.domid; ref = Int32.to_int g }) (Array.to_list grefs) in
           indirect_grants := grefs @ (!indirect_grants)
         | Direct _ -> ()
      );
    (* -- at this point the ring slots may be overwritten *)

    (* replace indirect requests with direct requests *)
    let indirect_grants_mapping = maybe_mapv false !indirect_grants in
    let q = List.map (fun req -> match req.Req.segs with
      | Req.Direct _ -> req
      | Req.Indirect [| gref |] ->
        let page = lookup_mapping gref in
        let segs = Blkproto.Req.get_segments page req.Req.nr_segs in
        { req with Req.segs = Req.Direct segs }
      | Req.Indirect _ ->
        printf "FATAL: unimplemented: more than 1 indirect descriptor page\n%!";
        failwith "unimplemented: more than 1 indirect descriptor page"
    ) !q in

    let writable_q, readonly_q = List.partition is_writable q in
    let grants_of_req req = match req.Req.segs with
      | Req.Indirect _ ->
        printf "FATAL: grants_of_req encountered Indirect\n%!";
        assert false (* replaced above *)
      | Req.Direct segs -> grants_of_segments (Array.to_list segs) in
    let writable_grants = List.concat (List.map grants_of_req writable_q) in
    let readonly_grants = List.concat (List.map grants_of_req readonly_q) in

    (* Make two big data mappings *)
    let writable_mapping = maybe_mapv true writable_grants in
    let readonly_mapping = maybe_mapv false readonly_grants in

    let bucket = if !counter < Array.length stats.ring_utilisation then !counter else Array.length stats.ring_utilisation - 1 in
    stats.ring_utilisation.(bucket) <- stats.ring_utilisation.(bucket) + 1;
    stats.total_requests <- stats.total_requests + (!counter);

    let _ = (* perform everything else in a background thread *)
      let open Block_request in
      let requests = List.fold_left (fun acc request ->
        let segs = match request.Req.segs with
         | Req.Indirect _ ->
           printf "FATAL: some Indirect descriptors were not dereferenced\n%!";
           assert false (* replaced above *)
         | Req.Direct segs -> Array.to_list segs in
        match request.Req.op with
        | None ->
          printf "FATAL: Unknown blkif request type\n%!";
          failwith "unknown blkif request type";
        | Some ((Req.Read | Req.Write) as op) ->
          (try
             let bufs = List.map (fun seg ->
              let page = lookup_mapping seg.Req.gref in
              let frag = Cstruct.sub page (seg.Req.first_sector * 512) ((seg.Req.last_sector - seg.Req.first_sector + 1) * 512) in
              frag) segs in
            add acc request.Req.id op request.Req.sector bufs
          with e ->
            printf "FATAL: failed to analyse request (%s)\n%!" (Printexc.to_string e);
            acc (* drop request on the floor, but frontend will be confused *)
          )
        | Some op ->
          printf "FATAL: Unhandled request type %s\n%!" (Req.string_of_op op);
          failwith "unhandled request type";
        ) empty q in
      let rec work remaining = match pop remaining with
      | [], _ -> return ()
      | now, later ->
        lwt () = Lwt_list.iter_p (fun r ->
          lwt result =
            try_lwt
              lwt () = (if r.op = Req.Read then t.ops.read else t.ops.write) r.sector r.buffers in
              return Res.OK
            with e ->
              return Res.Error in
          let open Res in
          let ok, error = List.fold_left (fun (ok, error) id ->
            let slot = Ring.Rpc.Back.(slot t.ring (next_res_id t.ring)) in
            (* These responses aren't visible until pushed (below) *)
            write_response (id, {op=Some r.Block_request.op; st=Some result}) slot;
            if result = OK then (ok + 1, error) else (ok, error + 1)
          ) (0, 0) r.id in
          stats.total_ok <- stats.total_ok + ok;
          stats.total_error <- stats.total_error + error;
          return ()
        ) now in
        work later in
      lwt () = work requests in

      (* We must unmap before pushing because the frontend will attempt
         to reclaim the pages (without this you get "g.e. still in use!"
         errors from Linux *)
      maybe_unmap readonly_mapping;
      maybe_unmap writable_mapping;
      maybe_unmap indirect_grants_mapping;
      (* Make the responses visible to the frontend *)
      let notify = Ring.Rpc.Back.push_responses_and_check_notify t.ring in
      if notify then Eventchn.notify t.xe t.evtchn;
      return () in

    lwt next = A.after t.evtchn after in
    loop_forever next in
  loop_forever A.program_start

let init xg xe domid ring_info ops =
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
    let ring_utilisation = Array.create (Ring.Rpc.Back.nr_ents ring + 1) 0 in
    let segments_per_request = Array.create (Blkproto.max_segments_per_request + 1) 0 in
    let total_requests = 0 and total_ok = 0 and total_error = 0 in
    let stats = { ring_utilisation; segments_per_request; total_requests; total_ok; total_error } in
    let t = { domid; xg; xe; evtchn; ops; parse_req; ring } in
    let th = service_thread t stats in
    on_cancel th (fun () ->
      let counter = ref 0 in
      Ring.Rpc.Back.ack_requests ring (fun _ -> incr counter);
      if !counter <> 0 then printf "FATAL: before unmapping, there were %d outstanding requests on the ring. Events lost?\n%!" !(counter); 
      let () = Gnttab.unmap_exn xg mapping in ()
    );
    th, stats

open X

let get_my_domid client =
  immediate client (fun xs ->
    try_lwt
      lwt domid = read xs "domid" in
      return (int_of_string domid)
    with Xs_protocol.Enoent _ -> return 0)

let mk_backend_path client name (domid,devid) =
  lwt self = get_my_domid client in
  return (Printf.sprintf "/local/domain/%d/backend/%s/%d/%d" self name domid devid)

let mk_frontend_path client (domid,devid) =
  return (Printf.sprintf "/local/domain/%d/device/vbd/%d" domid devid)

let writev client pairs =
  transaction client (fun xs ->
    Lwt_list.iter_s (fun (k, v) -> write xs k v) pairs
  )

let readv client path keys =
  lwt options = immediate client (fun xs ->
    Lwt_list.map_s (fun k ->
      try_lwt
        lwt v = read xs (path ^ "/" ^ k) in
        return (Some (k, v))
      with _ -> return None) keys
  ) in
  return (List.fold_left (fun acc x -> match x with None -> acc | Some y -> y :: acc) [] options)

let read_one client k = immediate client (fun xs ->
  try_lwt
    lwt v = read xs k in
    return (`OK v)
  with _ -> return (`Error ("failed to read: " ^ k)))

let write_one client k v = immediate client (fun xs -> write xs k v)

let exists client k = match_lwt read_one client k with `Error _ -> return false | _ -> return true

(* Request a hot-unplug *)
let request_close name (domid, devid) =
  lwt client = make () in
  lwt backend_path = mk_backend_path client name (domid,devid) in
  writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (Blkproto.State.to_assoc_list Blkproto.State.Closing))

let force_close (domid, device) =
  lwt client = make () in
  lwt frontend_path = mk_frontend_path client (domid, device) in
  write_one client (frontend_path ^ "/state") (Blkproto.State.to_string Blkproto.State.Closed) 

let run ?(max_indirect_segments=256) (id: string) name (domid,devid) =
  lwt client = make () in
  let xg = Gnttab.interface_open () in
  let xe = Eventchn.init () in

  let open BlockError in
  B.connect id >>= fun t ->

  lwt backend_path = mk_backend_path client name (domid,devid) in

  (* Tell xapi we've noticed the backend *)
  lwt () = write_one client
    (backend_path ^ "/" ^ Blkproto.Hotplug._hotplug_status)
    Blkproto.Hotplug._online in

  try_lwt 

    lwt info = B.get_info t in
   
    (* Write the disk information for the frontend *)
    let di = Blkproto.DiskInfo.(to_assoc_list {
      sector_size = info.B.sector_size;
      sectors = info.B.size_sectors;
      media = Media.Disk;
      mode = Mode.ReadWrite }) in
    (* Advertise indirect descriptors with the same default as Linux blkback *)
    let features = Blkproto.FeatureIndirect.(to_assoc_list { max_indirect_segments}) in
    lwt () = writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (di @ features)) in
    lwt frontend_path = match_lwt read_one client (backend_path ^ "/frontend") with
      | `Error x -> failwith x
      | `OK x -> return x in
   
    (* wait for the frontend to enter state Initialised *)
    lwt () = wait client (fun xs ->
      try_lwt
        lwt state = read xs (frontend_path ^ "/" ^ Blkproto.State._state) in
        if Blkproto.State.of_string state = Some Blkproto.State.Initialised
        || Blkproto.State.of_string state = Some Blkproto.State.Connected
        then return ()
        else raise Xs_protocol.Eagain
      with Xs_protocol.Enoent _ -> raise Xs_protocol.Eagain
    ) in

    lwt frontend = readv client frontend_path Blkproto.RingInfo.keys in
    let ring_info = match Blkproto.RingInfo.of_assoc_list frontend with
      | `OK x -> x
      | `Error x -> failwith x in
    printf "%s\n%!" (Blkproto.RingInfo.to_string ring_info);
    let device_read ofs bufs =
      try_lwt
        B.read t ofs bufs >>= fun () ->
        return ()
      with e ->
        printf "blkback: read exception: %s, offset=%Ld\n%!" (Printexc.to_string e) ofs;
        Lwt.fail e in
    let device_write ofs bufs =
      try_lwt
        B.write t ofs bufs >>= fun () ->
        return ()
      with e ->
        printf "blkback: write exception: %s, offset=%Ld\n%!" (Printexc.to_string e) ofs;
        Lwt.fail e in
    let be_thread, stats = init xg xe domid ring_info {
      read = device_read;
      write = device_write;
    } in
    lwt () = writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (Blkproto.State.to_assoc_list Blkproto.State.Connected)) in
    (* wait for the frontend to disappear or enter a Closed state *)
    lwt () = wait client (fun xs -> 
      try_lwt
        lwt state = read xs (frontend_path ^ "/state") in
        if Blkproto.State.of_string state <> (Some Blkproto.State.Closed)
        then raise Xs_protocol.Eagain
        else return ()
      with Xs_protocol.Enoent _ ->
        return ()
    ) in
    Lwt.cancel be_thread;
    Lwt.return stats
  with e ->
    printf "blkback caught %s\n%!" (Printexc.to_string e);
    lwt () = B.disconnect t in
    fail e

let create ?backend_domid name (domid, device) =
  lwt client = make () in
  (* Construct the device: *)
  lwt backend_path = mk_backend_path client name (domid, device) in
  lwt frontend_path = mk_frontend_path client (domid, device) in
  lwt backend_domid = match backend_domid with
  | None -> get_my_domid client
  | Some x -> return x in
  let c = Blkproto.Connection.({
    virtual_device = string_of_int device;
    backend_path;
    backend_domid;
    frontend_path;
    frontend_domid = domid;
    mode = Blkproto.Mode.ReadWrite;
    media = Blkproto.Media.Disk;
    removable = false;
  }) in
  transaction client (fun xs ->
    Lwt_list.iter_s (fun (owner_domid, (k, v)) ->
      lwt () = write xs k v in
      let acl =
        let open Xs_protocol.ACL in
        { owner = owner_domid; other = READ; acl = [ ] } in
      lwt () = setperms xs k acl in
      return ()
    ) (Blkproto.Connection.to_assoc_list c)
  )

let destroy name (domid, device) =
  lwt client = make () in
  lwt backend_path = mk_backend_path client name (domid, device) in
  lwt frontend_path = mk_frontend_path client (domid, device) in
  immediate client (fun xs ->
    lwt () = try_lwt rm xs backend_path with _ -> return () in
    lwt () = try_lwt rm xs frontend_path with _ -> return () in
    return ()
  )
end
