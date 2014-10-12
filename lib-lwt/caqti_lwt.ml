(* Copyright (C) 2014  Petter Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the OCaml static compilation exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 *)

include Caqti.Make (struct

  type 'a io = 'a Lwt.t
  let (>>=) = Lwt.(>>=)
  let return = Lwt.return
  let fail = Lwt.fail
  let join = Lwt.join
  let catch = Lwt.catch

  module Mvar = struct
    type 'a t = 'a Lwt_mvar.t
    let create = Lwt_mvar.create_empty
    let store x v = Lwt.async (fun () -> Lwt_mvar.put v x)
    let fetch = Lwt_mvar.take
  end

  module Log = struct
    open Lwt_log

    let section = Lwt_log.Section.make "caqti"
    let query_section = Lwt_log.Section.make "caqti.show-query"
    let tuple_section = Lwt_log.Section.make "caqti.show-tuple"

    let error_f q fmt = Lwt_log.error_f fmt
    let warning_f q fmt = Lwt_log.warning_f fmt
    let info_f q fmt = Lwt_log.info_f fmt

    let debug_f q fmt = Lwt_log.debug_f fmt

    let debug_enabled_for scn =
      match Lwt_log.Section.level scn with
      | Debug -> true
      | Info | Notice | Warning | Error | Fatal -> false

    let debug_query_enabled () = debug_enabled_for query_section
    let debug_tuple_enabled () = debug_enabled_for tuple_section

    let debug_query qi params =
      begin match qi with
      | `Oneshot qs ->
	Lwt_log.debug_f ~section:query_section "Sent query: %s" qs
      | `Prepared (qn, qs) ->
	Lwt_log.debug_f ~section:query_section "Sent query %s: %s" qn qs
      end >>= fun () ->
      if params = [] then
	Lwt.return_unit
      else
	Lwt_log.debug_f ~section:query_section "with parameters: %s"
			(String.concat ", " params)

    let debug_tuple tuple =
      Lwt_log.debug_f ~section:tuple_section "Received tuple: %s"
		      (String.concat ", " tuple)
  end

  module Unix = struct
    type file_descr = Lwt_unix.file_descr
    let wrap_fd f fd = f (Lwt_unix.of_unix_file_descr fd)
    let wait_read = Lwt_unix.wait_read
    let wait_write = Lwt_unix.wait_write
  end

  (* TODO: priority, idle shutdown *)
  module Pool = struct
    type 'a t = 'a Lwt_pool.t
    let create ?(max_size = 1) ?max_priority ?validate f =
      Lwt_pool.create max_size ?validate f
    let use ?priority f p = Lwt_pool.use p f
    let drain pool = return () (* FIXME *)
  end

  module Preemptive = Lwt_preemptive

end)
