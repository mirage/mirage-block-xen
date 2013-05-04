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

(* Control messages via xenstore *)

module Mode = struct
  type t = ReadOnly | ReadWrite
  let to_string = function
    | ReadOnly -> "r"
    | ReadWrite -> "w"
  let of_string = function
    | "r" -> Some ReadOnly
    | "w" -> Some ReadWrite
    | _ -> None
end

module Media = struct
  type t = CDROM | Disk
  let to_string = function
    | CDROM -> "cdrom"
    | Disk -> "disk"
  let of_string = function
    | "cdrom" -> Some CDROM
    | "disk" -> Some Disk
    | _ -> None
end

module State = struct
  type t = Initialising | InitWait | Initialised | Connected | Closing | Closed
  let table = [
    1, Initialising;
    2, InitWait;
    3, Initialised;
    4, Connected;
    5, Closing;
    6, Closed
  ]
  let table' = List.map (fun (x, y) -> y, x) table
  let to_string t = string_of_int (List.assoc t table' )
  let of_string t = try Some (List.assoc (int_of_string t) table) with _ -> None
end

module Configuration = struct
  type t = {
    virtual_device: string;
    backend_path: string;
    backend_domid: int;
    frontend_path: string;
    frontend_domid: int;
    mode: Mode.t;
    media: Media.t;
    removable: bool;
  }

  let to_assoc_list t =
    let backend = [
      "frontend-id", string_of_int t.frontend_domid;
      "online", "1";
      "removable", if t.removable then "1" else "0";
      "state", State.to_string State.Initialising;
      "mode", Mode.to_string t.mode;
    ] in
    let frontend = [
      "backend-id", string_of_int t.backend_domid;
      "state", State.to_string State.Initialising;
      "virtual-device", t.virtual_device;
      "device-type", Media.to_string t.media;
    ] in
    []
    @ (List.map (fun (k, v) -> Printf.sprintf "%s/%s" t.backend_path k, v) backend)
    @ (List.map (fun (k, v) -> Printf.sprintf "%s/%s" t.frontend_path k, v) frontend)
end

module Protocol = struct
  type t = X86_64 | X86_32 | Native

  let of_string = function
    | "x86_32-abi" -> Some X86_32
    | "x86_64-abi" -> Some X86_64
    | "native"     -> Some Native
    | _            -> None

  let to_string = function
    | X86_64 -> "x86_64-abi"
    | X86_32 -> "x86_32-abi"
    | Native -> "native"
end

(* Block requests; see include/xen/io/blkif.h *)
module Req = struct

  (* Defined in include/xen/io/blkif.h, BLKIF_REQ_* *)
  cenum op {
    Read          = 0;
    Write         = 1;
    Write_barrier = 2;
    Flush         = 3;
    Op_reserved_1 = 4; (* SLES device-specific packet *)
    Trim          = 5
  } as uint8_t

  let string_of_op = function
  | Read -> "Read" | Write -> "Write" | Write_barrier -> "Write_barrier"
  | Flush -> "Flush" | Op_reserved_1 -> "Op_reserved_1" | Trim -> "Trim"

  exception Unknown_request_type of int

  (* Defined in include/xen/io/blkif.h BLKIF_MAX_SEGMENTS_PER_REQUEST *)
  let segments_per_request = 11

  type seg = {
    gref: int32;
    first_sector: int;
    last_sector: int;
  }

  let string_of_seg seg =
    Printf.sprintf "{gref=%ld first=%d last=%d}" seg.gref seg.first_sector seg.last_sector

  let string_of_segs segs = 
    Printf.sprintf "[%s]" (String.concat "," (List.map string_of_seg (Array.to_list segs)))

  (* Defined in include/xen/io/blkif.h : blkif_request_t *)
  type t = {
    op: op option;
    handle: int;
    id: int64;
    sector: int64;
    segs: seg array;
  }

  let string_of t =
    Printf.sprintf "op=%s\nhandle=%d\nid=%Ld\nsector=%Ld\nsegs=%s\n"
    (match t.op with Some x -> string_of_op x | None -> "None")
      t.handle t.id t.sector (string_of_segs t.segs)

  (* The segment looks the same in both 32-bit and 64-bit versions *)
  cstruct segment {
    uint32_t       gref;
    uint8_t        first_sector;
    uint8_t        last_sector;
    uint16_t       _padding
  } as little_endian
  let _ = assert (sizeof_segment = 8)

  (* The request header has a slightly different format caused by
     not using __attribute__(packed) and letting the C compiler pad *)
  module type PROTO = sig
    val sizeof_hdr: int
    val get_hdr_op: Cstruct.t -> int
    val set_hdr_op: Cstruct.t -> int -> unit
    val get_hdr_nr_segs: Cstruct.t -> int
    val set_hdr_nr_segs: Cstruct.t -> int -> unit
    val get_hdr_handle: Cstruct.t -> int
    val set_hdr_handle: Cstruct.t -> int -> unit
    val get_hdr_id: Cstruct.t -> int64
    val set_hdr_id: Cstruct.t -> int64 -> unit
    val get_hdr_sector: Cstruct.t -> int64
    val set_hdr_sector: Cstruct.t -> int64 -> unit
  end

  module Marshalling = functor(P: PROTO) -> struct
    open P
    (* total size of a request structure, in bytes *)
    let total_size = sizeof_hdr + (sizeof_segment * segments_per_request)

    (* Write a request to a slot in the shared ring. *)
    let write_request req (slot: Cstruct.t) =
      set_hdr_op slot (match req.op with None -> -1 | Some x -> op_to_int x);
      set_hdr_nr_segs slot (Array.length req.segs);
      set_hdr_handle slot req.handle;
      set_hdr_id slot req.id;
      set_hdr_sector slot req.sector;
      let payload = Cstruct.shift slot sizeof_hdr in
      Array.iteri (fun i seg ->
          let buf = Cstruct.shift payload (i * sizeof_segment) in
          set_segment_gref buf seg.gref;
          set_segment_first_sector buf seg.first_sector;
          set_segment_last_sector buf seg.last_sector
      ) req.segs;
      req.id

    (* Read a request out of an Cstruct.t; to be used by the Ring.Back for serving
       requests, so this is untested for now *)
    let read_request slot =
      let payload = Cstruct.shift slot sizeof_hdr in
      let segs = Array.init (get_hdr_nr_segs slot) (fun i ->
          let seg = Cstruct.shift payload (i * sizeof_segment) in {
              gref = get_segment_gref seg;
              first_sector = get_segment_first_sector seg;
              last_sector = get_segment_last_sector seg;
          }
      ) in {
          op = int_to_op (get_hdr_op slot);
          handle = get_hdr_handle slot;
          id = get_hdr_id slot;
          sector = get_hdr_sector slot;
          segs = segs
      }

  end
  module Proto_64 = Marshalling(struct
    cstruct hdr {
      uint8_t        op;
      uint8_t        nr_segs;
      uint16_t       handle;
      uint32_t       _padding; (* emitted by C compiler *)
      uint64_t       id;
      uint64_t       sector
    } as little_endian
  end)
  module Proto_32 = Marshalling(struct
    cstruct hdr {
      uint8_t        op;
      uint8_t        nr_segs;
      uint16_t       handle;
      (* uint32_t       _padding; -- not included *)
      uint64_t       id;
      uint64_t       sector
    } as little_endian
  end)
end

module Res = struct

  (* Defined in include/xen/io/blkif.h, BLKIF_RSP_* *)
  cenum rsp {
    OK            = 0;
    Error         = 0xffff;
    Not_supported = 0xfffe
  } as uint16_t

  (* Defined in include/xen/io/blkif.h, blkif_response_t *)
  type t = {
    op: Req.op option;
    st: rsp option;
  }

  (* The same structure is used in both the 32- and 64-bit protocol versions,
     modulo the extra padding at the end. *)
  cstruct response_hdr {
    uint64_t       id;
    uint8_t        op;
    uint8_t        _padding;
    uint16_t       st;
    (* 64-bit only but we don't need to care since there aren't any more fields: *)
    uint32_t       _padding
  } as little_endian

  let write_response (id, t) slot =
    set_response_hdr_id slot id;
    set_response_hdr_op slot (match t.op with None -> -1 | Some x -> Req.op_to_int x);
    set_response_hdr_st slot (match t.st with None -> -1 | Some x -> rsp_to_int x)

  let read_response slot =
    get_response_hdr_id slot, {
      op = Req.int_to_op (get_response_hdr_op slot);
      st = int_to_rsp (get_response_hdr_st slot)
    }
end
