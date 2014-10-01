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
open Blkproto
open Gnt
open OS

type 'a io = 'a Lwt.t

type page_aligned_buffer = Cstruct.t

type info = {
  read_write: bool;
  sector_size: int;
  size_sectors: int64;
}

type transport = {
  backend_id: int;
  backend: string;
  ring: (Res.t,int64) Ring.Rpc.Front.t;
  client: (Res.t,int64) Lwt_ring.Front.t;
  gnts: Gnt.gntref list;
  evtchn: Eventchn.t;
  max_indirect_segments: int;
  info: info;
}

type t = {
  vdev: int;
  mutable t: transport
}

type id = string
exception IO_error of string

(** slot number (e.g. "51712") to device threads *)
let devices : (id, t Lwt.t) Hashtbl.t = Hashtbl.create 16

let h = Eventchn.init ()

(* Allocate a ring, given the vdev and backend domid *)
let alloc ~order (num,domid) =
  let name = sprintf "Blkif.%d" num in
  let idx_size = Req.Proto_64.total_size in (* bigger than res *)
  let buf = Io_page.get_order order in

  let pages = Io_page.to_pages buf in
  lwt gnts = Gntshr.get_n (List.length pages) in
  List.iter (fun (gnt, page) -> 
      Gntshr.grant_access ~domid ~writable:true gnt page) 
    (List.combine gnts pages);

  let sring = Ring.Rpc.of_buf ~buf:(Io_page.to_cstruct buf) ~idx_size ~name in
  printf "Blkfront %s\n%!" (Ring.Rpc.to_summary_string sring);
  let fring = Ring.Rpc.Front.init ~sring in
  let client = Lwt_ring.Front.init Int64.to_string fring in
  return (gnts, fring, client)

(* Thread to poll for responses and activate wakeners *)
let poll t =
  let rec loop from =
    lwt next = Activations.after t.evtchn from in
    let () = Lwt_ring.Front.poll t.client (Res.read_response) in
    loop next in
  loop Activations.program_start

(* Given a VBD ID and a backend domid, construct a blkfront record.
   Note the logic in Block.connect below to only call this once per device *)
let plug (id:id) =
  lwt vdev = try return (int_of_string id)
    with _ -> fail (Failure "invalid vdev") in
  printf "Blkfront.create; vdev=%d\n%!" vdev;
  let node = sprintf "device/vbd/%d/%s" vdev in

  lwt xs = Xs.make () in
  lwt backend_id = Xs.(immediate xs (fun h -> read h (node "backend-id"))) in
  lwt backend_id = try_lwt return (int_of_string backend_id)
    with _ -> fail (Failure "invalid backend_id") in
  lwt backend = Xs.(immediate xs (fun h -> read h (node "backend"))) in

  let backend_read fn default k =
    let backend = sprintf "%s/%s" backend in
    try_lwt
      lwt s = Xs.(immediate xs (fun h -> read h (backend k))) in
      return (fn s)
    with exn -> return default in

  (* The backend can advertise a multi-page ring: *)
  lwt backend_max_ring_page_order = backend_read int_of_string 0 "max-ring-page-order" in
  if backend_max_ring_page_order = 0
  then printf "Blkback can only use a single-page ring\n%!"
  else printf "Blkback advertises multi-page ring (size 2 ** %d pages)\n%!" backend_max_ring_page_order;

  let our_max_ring_page_order = 2 in (* 4 pages *)
  let ring_page_order = min our_max_ring_page_order backend_max_ring_page_order in
  printf "Negotiated a %s\n%!" 
    (if ring_page_order = 0 then 
       "single-page ring" else 
       sprintf "multi-page ring (size 2 ** %d pages)" ring_page_order);

  lwt (gnts, ring, client) = alloc ~order:ring_page_order (vdev,backend_id) in
  let evtchn = Eventchn.bind_unbound_port h backend_id in
  let port = Eventchn.to_int evtchn in
  let ring_info =
    (* The new protocol writes (ring-refN = G) where N=0,1,2 *)
    let rfs = snd(List.fold_left (fun (i, acc) g ->
        i + 1, ((sprintf "ring-ref%d" i, string_of_int g) :: acc)
      ) (0, []) gnts) in
    if ring_page_order = 0
    then [ "ring-ref", string_of_int (List.hd gnts) ] (* backwards compat *)
    else [ "ring-page-order", string_of_int ring_page_order ] @ rfs in
  let info = [
    "event-channel", string_of_int port;
    "protocol", "x86_64-abi";
    "state", Device_state.(to_string Connected)
  ] @ ring_info in
  lwt () = Xs.(transaction xs (fun h ->
      Lwt_list.iter_s (fun (k, v) -> write h (node k) v) info
    )) in
  lwt () = Xs.(wait xs (fun h ->
      lwt state = read h (sprintf "%s/state" backend) in
      if Device_state.(of_string state = Connected) then return () else fail Xs_protocol.Eagain
    )) in
  (* Read backend info *)
  lwt max_indirect_segments = backend_read int_of_string 0 FeatureIndirect._max_indirect_segments in
  (* Limit to one page for now *)
  let max_indirect_segments = min max_indirect_segments Req.Proto_64.segments_per_indirect_page in
  lwt info =
    lwt state = backend_read (Device_state.of_string) Device_state.Unknown "state" in
    printf "state=%s\n%!" (Device_state.prettyprint state);
    lwt size_sectors = backend_read Int64.of_string (-1L) "sectors" in
    lwt sector_size = backend_read int_of_string 0 "sector-size" in
    lwt read_write = backend_read (fun x -> x = "w") false "mode" in
    return { sector_size; size_sectors; read_write }
  in
  printf "Blkfront info: sector_size=%u sectors=%Lu max_indirect_segments=%d\n%!"
    info.sector_size info.size_sectors max_indirect_segments;
  Eventchn.unmask h evtchn;
  let t = { backend_id; backend; ring; client; gnts; evtchn; max_indirect_segments; info } in
  (* Start the background poll thread *)
  let _ = poll t in
  return t

(* Unplug shouldn't block, although the Xen one might need to due
   to Xenstore? XXX *)
let unplug id =
  printf "Blkif.unplug %s: not implemented yet\n" id

(** Return a list of valid VBDs *)
let enumerate () =
  lwt xs = Xs.make () in
  try_lwt
    Xs.(immediate xs (fun h -> directory h "device/vbd"))
  with
  | Xs_protocol.Enoent _ ->
    return []
  | e ->
    printf "Blkif.enumerate caught exception: %s\n" (Printexc.to_string e);
    return []

(** Return a list of pairs [backend-params-key, frontend-id].
    This is only intended to be a heuristic for 'connect' below. *)
let params_to_frontend_ids ids =
  lwt xs = Xs.make () in
  Lwt_list.fold_left_s (fun list id ->
    try_lwt
      lwt backend = Xs.(immediate xs (fun h -> read h (Printf.sprintf "device/vbd/%s/backend" id))) in
      lwt params = Xs.(immediate xs (fun h -> read h (Printf.sprintf "%s/params" backend))) in
      return ((params, id) :: list)
    with Xs_protocol.Enoent path ->
      printf "Blkif.params_to_frontend_ids: missing %s\n" path;
      return list
    | e ->
      printf "Blkif.params_to_frontend_ids caught exception: %s\n" (Printexc.to_string e);
      return list
  ) [] ids

(** Create a Direct request if we have 11 or fewer requests, else an Indirect request. *)
let with_segs t ~start_offset ~end_offset rs fn =
  let len = Array.length rs in
  let segs = Array.mapi (fun i rf ->
      let first_sector = match i with
        | 0 -> start_offset
        | _ -> 0 in
      let last_sector = match i with
        | n when n == len-1 -> end_offset
        | _ -> 7 in
      let gref = Int32.of_int rf in
      { Req.gref; first_sector; last_sector }
    ) rs in
  if len <= 11 then (
    fn (Req.Direct segs)
  ) else (
    (* The protocol allows up to 8 pages, but at 512 entries each it's unlikely
     * we'll want more than one. The Linux blkback limits us to 256 by default
     * anyway. *)
    let indirect_page = Io_page.get 1 in
    Req.Proto_64.write_segments segs (Io_page.to_cstruct indirect_page);
    Gntshr.with_ref (fun indirect_ref ->
      Gntshr.with_grant ~domid:t.t.backend_id ~writable:false indirect_ref indirect_page (fun () ->
        fn (Req.Indirect [| Int32.of_int indirect_ref |])
      )
    )
  )

(** [single_request_into op t start_sector start_offset end_offset pages]
    issues a single request [op], starting at [start_sector] and using
    the memory [pages] as either the target of data (if [op] is Read) or the
    source of data (if [op] is Write). If the sector size is less than a page
    then [start_offset] and [end_offset] can be used to start and finish the
    data on sub-page sector boundaries in the first and last pages. *)
let single_request_into op t start_sector ?(start_offset=0) ?(end_offset=7) pages =
  let len = List.length pages in
  let rec retry () =
    try_lwt
      Gntshr.with_refs len
        (fun rs ->
           Gntshr.with_grants ~domid:t.t.backend_id ~writable:(op = Req.Read) rs pages
             (fun () ->
                let rs = Array.of_list rs in
                let nr_segs = Array.length rs in
                with_segs t ~start_offset ~end_offset rs (fun segs ->
                  let id = Int64.of_int rs.(0) in
                  let sector = Int64.(add start_sector (of_int start_offset)) in
                  let req = Req.({ op=Some op; handle=t.vdev; id; sector; nr_segs; segs }) in
                  lwt res = Lwt_ring.Front.push_request_and_wait t.t.client
                      (fun () -> Eventchn.notify h t.t.evtchn)
                      (Req.Proto_64.write_request req) in
                  let open Res in
                  match res.st with
                  | Some Error -> fail (IO_error "read")
                  | Some Not_supported -> fail (IO_error "unsupported")
                  | None -> fail (IO_error "unknown error")
                  | Some OK -> return ()
                )
             )
        )
    with
    | Lwt_ring.Shutdown -> retry ()
    | exn -> fail exn in
  retry ()

(* THIS FUNCTION IS DEPRECATED. Use 'write' instead.

   Write a single page to disk.
   Offset is in bytes, which must be sector-aligned
   Page must be an Io_page *)
let rec write_page t offset page =
  let sector = Int64.(div offset (of_int t.t.info.sector_size)) in
  if not t.t.info.read_write
  then fail (IO_error "read-only")
  else single_request_into Req.Write t sector [ page ]


(* THIS FUNCTION IS DEPRECATED. Use 'read' instead.

   Reads [num_sectors] starting at [sector], returning a stream of Io_page.ts *)
let read_512 t sector num_sectors =
  let module Single_request = struct
    (** A large request must be broken down into a series of smaller page-aligned requests: *)
    type t = {
      start_sector: int64; (* page-aligned sector to start reading from *)
      start_offset: int;   (* sector offset into the page of our data *)
      end_sector: int64;   (* last page-aligned sector to read *)
      end_offset: int;     (* sector offset into the page of our data *)
    }

    (** Number of pages required to issue this request *)
    let npages_of t = Int64.(to_int (div (sub t.end_sector t.start_sector) 8L))

    let to_string t =
      sprintf "(%Lu, %u) -> (%Lu, %u)" t.start_sector t.start_offset t.end_sector t.end_offset

    (* Transforms a large read of [num_sectors] starting at [sector] into a Lwt_stream
       of single_requests, where each request will fit on the ring. *)
    let stream_of sector num_sectors =
      let from (sector, num_sectors) =
        assert (sector >= 0L);
        assert (num_sectors > 0L);
        (* Round down the starting sector in order to get a page aligned sector *)
        let start_sector = Int64.(mul 8L (div sector 8L)) in
        let start_offset = Int64.(to_int (sub sector start_sector)) in
        (* Round up the ending sector to the page boundary *)
        let end_sector = Int64.(mul 8L (div (add (add sector num_sectors) 7L) 8L)) in
        (* Calculate number of sectors needed *)
        let total_sectors_needed = Int64.(sub end_sector start_sector) in
        (* Maximum of 11 segments per request; 1 page (8 sectors) per segment so: *)
        let total_sectors_possible = min 88L total_sectors_needed in
        let possible_end_sector = Int64.add start_sector total_sectors_possible in
        let end_offset = min 7 (Int64.(to_int (sub 7L (sub possible_end_sector (add sector num_sectors))))) in

        let first = { start_sector; start_offset; end_sector = possible_end_sector; end_offset } in
        if total_sectors_possible < total_sectors_needed
        then
          let num_sectors = Int64.(sub num_sectors (sub total_sectors_possible (of_int start_offset))) in
          first, Some ((Int64.add start_sector total_sectors_possible), num_sectors)
        else
          first, None in
      let state = ref (Some (sector, num_sectors)) in
      Lwt_stream.from
        (fun () ->
           match !state with
           | None -> return None
           | Some x ->
             let item, state' = from x in
             state := state';
             return (Some item)
        )

    let list_of sector num_sectors =
      Lwt_stream.to_list (stream_of sector num_sectors)
  end in
  let requests = Single_request.stream_of sector num_sectors in
  let read_single_request t r =
    let open Single_request in
    let len = npages_of r in
    let pages = Io_page.(to_pages (get len)) in
    lwt () = single_request_into Req.Read t r.start_sector 
        ~start_offset:r.start_offset ~end_offset:r.end_offset pages in
    return (Lwt_stream.of_list 
              (List.rev 
                 (snd 
                    (List.fold_left
                       (fun (i, acc) page ->
                          let start_offset = match i with
                            |0 -> r.start_offset * 512
                            |_ -> 0 in
                          let end_offset = match i with
                            |n when n = len-1 -> (r.end_offset + 1) * 512
                            |_ -> 4096 in
                          let bytes = end_offset - start_offset in
                          let subpage = Cstruct.sub (Io_page.to_cstruct page) start_offset bytes in
                          i + 1, subpage :: acc
                       ) (0, []) pages
                    )))) in
  Lwt_stream.(concat (map_s (read_single_request t) requests))

let resume t =
  let vdev = sprintf "%d" t.vdev in
  lwt transport = plug vdev in
  let old_t = t.t in
  t.t <- transport;
  Lwt_ring.Front.shutdown old_t.client;
  return ()

let resume () =
  let devs = Hashtbl.fold (fun k v acc -> (k,v)::acc) devices [] in
  Lwt_list.iter_p (fun (k,v) ->
    lwt v = v in
    resume v
  ) devs

let disconnect _id =
  printf "Blkfront: disconnect not implement yet\n";
  return ()

type error =
  [ `Disconnected
  | `Is_read_only
  | `Unimplemented
  | `Unknown of string ]

(* [take xs n] returns [(taken, remaining)] where [taken] is as many
   elements of [xs] as possible, up to [n], and [remaining] is any
   that are left over. *)
let take xs n =
  let rec loop taken remaining n = match n, remaining with
    | 0, _
    | _, [] -> List.rev taken, remaining
    | n, x :: xs -> loop (x :: taken) xs (n - 1) in
  loop [] xs n

(* Upgrade sector_size to be at least a page to guarantee read/write
   is page-aligned as well as sector-aligned. 4k sector size disks
   are becoming more common, so we might as well be ready. *)
let minimum_sector_size = 4096

let get_sector_size t =
  max t.t.info.sector_size minimum_sector_size

let sector t x =
  if t.t.info.sector_size >= 4096
  then x
  else Int64.(div (mul x (of_int minimum_sector_size)) (of_int t.t.info.sector_size))

let get_info t =
  let sector_size = get_sector_size t in
  let size_sectors = Int64.(
      div t.t.info.size_sectors 
        (of_int (sector_size / t.t.info.sector_size))) in
  let info = { t.t.info with sector_size; size_sectors } in
  return info

let rec multiple_requests_into op t start_sector = function
  | [] -> return ()
  | remaining ->
    let max_segments_per_request = max 11 t.t.max_indirect_segments in
    let pages, remaining = take remaining max_segments_per_request in
    lwt () = single_request_into op t start_sector pages in
    let start_sector = Int64.(add start_sector (of_int (max_segments_per_request * 4096 / t.t.info.sector_size))) in
    multiple_requests_into op t start_sector remaining

let connect id =
  if Hashtbl.mem devices id then begin
    lwt d = Hashtbl.find devices id in
    return (`Ok d)
  end else begin
    lwt all = enumerate () in
    lwt list = params_to_frontend_ids all in
    (* Apply a set of heuristics to locate the disk:
       if [id] is a xen virtual disk bus slot number (e.g. 51712) then use it
       if [id] is a "linux device string" (e.g. "xvda" or "/dev/xvda") then translate it
       if [id] is a unique backend "params" xenstore key then use it
    *)
    let choice =
      if List.mem id all then begin
        printf "Block.connect %s: interpreting %s as a xen virtual disk bus slot number\n" id id;
        Some id
      end else begin
        let id' =
          let prefix = "/dev/" in
          let prefix' = String.length prefix and id' = String.length id in
          let stripped =
            if prefix' <= id' && (String.sub id 0 prefix' = prefix)
            then String.sub id prefix' (id' - prefix') else id in
          try
            let device = Device_number.of_linux_device stripped in
            string_of_int (Device_number.to_xenstore_key device)
          with _ -> id in
        if List.mem id' all then begin
          printf "Block.connect %s: interpreting %s as a linux device string, translating to %s\n" id id id';
          Some id'
        end else begin
          match List.map snd (List.filter (fun (params, _) -> params = id) list), all with
          | [ id' ], _ ->
            printf "Block.connect %s: interpreting %s as a backend params key, translating to %s\n" id id id';
            Some id'
          | first :: rest, _ ->
            printf "Block.connect %s: name is ambiguous: it matches multiple backend params keys [ %s ]" id (String.concat "; " (first::rest));
            None
          | _, _ ->
            printf "Block.connect %s: unable to match '%s' to any available devices [ %s ]\n" id id (String.concat "; " all);
            None
        end
      end in
    match choice with
    | Some id' when Hashtbl.mem devices id' ->
      let t = Hashtbl.find devices id' in
      Hashtbl.replace devices id t;
      lwt d = t in
      return (`Ok d)
    | Some id' ->
      printf "Block.connect %s -> %s\n%!" id id';
      let t, u = Lwt.task () in
      Hashtbl.replace devices id' t;
      Hashtbl.replace devices id t;
      (* id' is now in devices, so no-one will call plug in parallel with us *)
      lwt trans = plug id' in
      let dev = { vdev = int_of_string id';
                  t = trans } in
      Lwt.wakeup u dev;
      return (`Ok dev)
    | None ->
      printf "Block.connect %s: could not find device\n" id;
      return (`Error (`Unknown 
                        (Printf.sprintf "device %s not found (available = [ %s ])" 
                           id (String.concat ", " all)))) 
  end

let id t = string_of_int t.vdev

exception Buffer_is_not_page_aligned
exception Buffer_is_more_than_one_page
let to_iopage x =
  if x.Cstruct.off <> 0 then raise Buffer_is_not_page_aligned;
  if x.Cstruct.len > 4096 then raise Buffer_is_more_than_one_page;
  x.Cstruct.buffer

let to_iopages x =
  try return (List.map to_iopage x)
  with e -> fail e

let ( >>= ) x f = match x with
  | `Error _ -> x
  | `Ok x -> f x

let read t start_sector pages =
  lwt pages = to_iopages pages in
  try_lwt
    lwt () = multiple_requests_into Req.Read t (sector t start_sector) pages in
    return (`Ok ())
  with e -> return (`Error (`Unknown (Printexc.to_string e)))

let write t start_sector pages =
  lwt pages = to_iopages pages in
  try_lwt
    lwt () = multiple_requests_into Req.Write t (sector t start_sector) pages in
    return (`Ok ())
  with e -> return (`Error (`Unknown (Printexc.to_string e)))

let _ =
  printf "Blkif: add resume hook\n%!";
  Sched.add_resume_hook resume
