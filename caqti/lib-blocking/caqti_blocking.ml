(* Copyright (C) 2018--2022  Petter A. Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the LGPL-3.0 Linking Exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * and the LGPL-3.0 Linking Exception along with this library.  If not, see
 * <http://www.gnu.org/licenses/> and <https://spdx.org>, respectively.
 *)

open Caqti_private
open Caqti_private.Std

module System = struct

  type 'a future = 'a
  let (>>=) x f = f x
  let (>|=) x f = f x
  let return x = x

  let catch f g = try f () with exn -> g exn

  let finally f g =
    (match f () with
     | y -> g (); y
     | exception exn -> g (); raise exn)

  let cleanup f g = try f () with exn -> g (); raise exn

  let join (_ : unit list) = ()

  module Mvar = struct
    type 'a t = 'a option ref
    let create () = ref None
    let store x v = v := Some x
    let fetch v =
      (match !v with
       | None -> failwith "Attempt to fetch empty mvar from blocking client."
       | Some x -> x)
  end

  module Log = struct
    type 'a log = 'a Logs.log
    let err ?(src = default_log_src) = Logs.err ~src
    let warn ?(src = default_log_src) = Logs.warn ~src
    let info ?(src = default_log_src) = Logs.info ~src
    let debug ?(src = default_log_src) = Logs.debug ~src
  end

  module Sequencer = struct
    type 'a t = 'a
    let create m = m
    let enqueue m f = f m
  end

  module Networking = struct
    type nonrec in_channel = in_channel
    type nonrec out_channel = out_channel
    type sockaddr = Unix of string | Inet of string * int

    (* From pgx_unix. *)
    let open_connection sockaddr =
      let std_socket =
        match sockaddr with
        | Unix path -> Unix.ADDR_UNIX path
        | Inet (hostname, port) ->
          let hostent = Unix.gethostbyname hostname in
          (* Choose a random address from the list. *)
          let addrs = hostent.Unix.h_addr_list in
          let len = Array.length addrs in
          let i = Random.int len in
          let addr = addrs.(i) in
          Unix.ADDR_INET (addr, port)
      in
      Unix.open_connection std_socket

    let output_char = output_char
    let output_string = output_string
    let flush = flush
    let input_char = input_char
    let really_input = really_input
    let close_in = close_in
  end

  module Unix = struct
    type file_descr = Unix.file_descr
    let wrap_fd f fd = f fd
    let poll ?(read = false) ?(write = false) ?(timeout = -1.0) fd =
      let read_fds = if read then [fd] else [] in
      let write_fds = if write then [fd] else [] in
      let read_fds, write_fds, _ = Unix.select read_fds write_fds [] timeout in
      (read_fds <> [], write_fds <> [], read_fds = [] && write_fds = [])
  end

  module Preemptive = struct
    let detach f x = f x
    let run_in_main f = f ()
  end

  module Stream = Caqti_private.Stream.Make (struct
    type 'a future = 'a
    let (>>=) x f = f x
    let (>|=) x f = f x
    let return x = x
  end)

end

module Loader = struct
  module Platform_unix = Caqti_platform_unix.Driver_loader.Make (System)
  module Platform_net = Caqti_platform_net.Driver_loader.Make (System)

  module type DRIVER = Platform_unix.DRIVER

  let load_driver ~uri scheme =
    (match Platform_net.load_driver ~uri scheme with
     | Ok _ as r -> r
     | Error (`Load_rejected _) as r -> r
     | Error (`Load_failed _) ->
        (* TODO: Summarize errors. *)
        Platform_unix.load_driver ~uri scheme)
end

include Connector.Make_without_connect (System)
include Connector.Make_connect (System) (Loader)

let or_fail = function
 | Ok x -> x
 | Error (#Caqti_error.t as err) -> raise (Caqti_error.Exn err)
