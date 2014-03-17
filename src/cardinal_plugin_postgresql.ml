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

open Cardinal_plugin
open Cardinal_query
open Cardinal_sigs
open Postgresql
open Printf

let utc_of_timestamp s =
  let n = String.length s in
  let fmt, s =
    if n <= 19 then
      ("%F %T%:::z", s ^ "+00") else
    if s.[19] <> '.' then
      ((if n = 22 then "%F %T%:::z" else "%F %T%z"), s) else
    let s0 = String.sub s 0 19 in
    if s.[n - 5] = '+' || s.[n - 5] = '-' then
      ("%F %T%z", s0 ^ String.sub s (n - 5) 5) else
    if s.[n - 3] = '+' || s.[n - 3] = '-' then
      ("%F %T%:::z", s0 ^ String.sub s (n - 3) 3) else
    ("%F %T%:::z", s0 ^ "+00") in
  CalendarLib.Printer.Calendar.from_fstring fmt s

module Param = struct
  let null = null
  let option f = function None -> null | Some x -> f x
  let bool x = string_of_bool x
  let int x = string_of_int x
  let int64 x = Int64.to_string x
  let float x = string_of_float x
  let string s = s
  let date t = CalendarLib.Printer.Date.sprint "%F" t
  let utc t = CalendarLib.Printer.Calendar.sprint "%F %T%z" t
end

module Tuple = struct

  let length (i, r) = r#nfields

  let raw j (i, r) =
    try r#getvalue i j with Error msg ->
    raise (Invalid_argument (string_of_error msg))

  let is_null j (i, r) =
    try r#getisnull i j with Error msg ->
    raise (Invalid_argument (string_of_error msg))
  let option f j (i, r) =
    if is_null j (i, r) then None else Some (f j (i, r))

  let bool j t =
    match raw j t with
    | "t" -> true
    | "f" -> false
    | _ -> failwith "bool_of_pgbool: Expecting \"t\" or \"f\"."
  let int j t = int_of_string (raw j t)
  let int64 j t = Int64.of_string (raw j t)
  let float j t = float_of_string (raw j t)
  let string j t = raw j t
  let date j t = CalendarLib.Printer.Date.from_fstring "%F" (raw j t)
  let utc j t = utc_of_timestamp (raw j t)
end

let escaped_connvalue s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun ch -> if ch = '\\' || ch = '\'' then Buffer.add_char buf '\\';
	       Buffer.add_char buf ch)
    s;
  Buffer.contents buf

module Connect_functor = struct
module Make (System : SYSTEM) = struct

  open System

  type 'a io = 'a System.io

  let query_language =
    create_query_language ~name:"postgresql" ~tag:`PostgreSQL ()

  let miscommunication uri q fmt =
    ksprintf (fun s -> fail (Cardinal.Miscommunication (uri, q, s))) fmt

  let prepare_failed uri q msg = fail (Cardinal.Prepare_failed (uri, q, msg))
  let execute_failed uri q msg = fail (Cardinal.Execute_failed (uri, q, msg))

  class connection uri =
    (* Connection URIs were introduced in version 9.2, so deconstruct URIs of
     * the form postgresql:/?query-string to provide a way to pass a connection
     * string which is valid for earlier versions. *)
    let conninfo =
      if Uri.host uri <> None then Uri.to_string uri else
      let mkparam k v = k ^ " = '" ^ escaped_connvalue v ^ "'" in
      String.concat " "
	(List.flatten (List.map (fun (k, vs) -> List.map (mkparam k) vs)
				(Uri.query uri))) in
  object (self)
    inherit Postgresql.connection ~conninfo ()

    val prepared_queries = Hashtbl.create 11

    (* Private Methods for Fetching Results *)

    method private wait_for_result =
      let socket_fd = Unix.of_unix_file_descr (Obj.magic self#socket) in
      let rec hold () =
	self#consume_input;
	if self#is_busy then Unix.wait_read socket_fd >>= hold
			else return () in
      hold ()

    method private fetch_result_io q =
      self#wait_for_result >>= fun () ->
      return self#get_result

    method private fetch_single_result_io q =
      self#fetch_result_io q >>= function
      | None -> miscommunication uri q "Missing response from DB."
      | Some r ->
	self#fetch_result_io q >>=
	begin function
	| None -> return r
	| Some r -> miscommunication uri q "Unexpected multi-response from DB."
	end

    (* Direct Execution *)

    method exec_io ?params ?binary_params qs =
      try
	self#send_query ?params ?binary_params qs;
	self#fetch_single_result_io (Oneshot qs)
      with
      | Postgresql.Error err ->
	execute_failed uri (Oneshot qs) (Postgresql.string_of_error err)
      | xc -> fail xc

    (* Prepared Execution *)

    method maybe_prepare ({prepared_index; prepared_name; prepared_sql} as pq) =
      try return (Hashtbl.find prepared_queries prepared_index)
      with Not_found ->
	let sql = prepared_sql query_language in
	begin try
	  self#send_prepare prepared_name sql;
	  self#fetch_single_result_io (Prepared pq)
	with
	| Postgresql.Error err ->
	  prepare_failed uri pq (Postgresql.string_of_error err)
	| xc -> fail xc
	end >>= fun r ->
	begin match r#status with
	| Command_ok ->
	  let binary_params =
	    let n = r#ntuples in
	    let is_binary i = r#paramtype i = BYTEA in
	    let rec has_binary i =
	      i < n && (is_binary i || has_binary (i + 1)) in
	    if has_binary 0 then Some (Array.init r#ntuples is_binary)
			    else None in
	  Hashtbl.add prepared_queries prepared_index binary_params;
	  return binary_params
	| Bad_response | Nonfatal_error | Fatal_error ->
	  prepare_failed uri pq r#error
	| _ ->
	  miscommunication uri (Prepared pq)
	    "Expected Command_ok or an error as response to prepare."
	end

    method exec_prepared_io ?params ({prepared_name} as pq) =
      self#maybe_prepare pq >>= fun binary_params ->
      try
	self#send_query_prepared ?params ?binary_params prepared_name;
	self#fetch_single_result_io (Prepared pq)
      with
      | Postgresql.Error err ->
	execute_failed uri (Prepared pq) (Postgresql.string_of_error err)
      | xc -> fail xc
  end

  module type CONNECTION = CONNECTION with type 'a io = 'a System.io

  let connect ?(max_pool_size = 1) uri =
    let pool =
      let connect () =
	try return (new connection uri)
	with Error e ->
	  fail (Cardinal.Connect_failed (uri, Postgresql.string_of_error e)) in
      let validate c =
	try c#try_reset; return true
	with _ -> return false in (* TODO: Log here or in Pool *)
      Pool.create ~validate ~max_size:max_pool_size connect in

    return (module struct
      type 'a io = 'a System.io
      type param = string
      type tuple = int * Postgresql.result

      let drain () = Pool.drain pool

      let use f = Pool.use f pool

      let check_command_ok q r =
	match r#status with
	| Command_ok -> return ()
	| Bad_response | Nonfatal_error | Fatal_error ->
	  execute_failed uri q r#error
	| _ ->
	  miscommunication uri q "Expected Command_ok or an error response."

      let check_tuples_ok q r =
	begin match r#status with
	| Tuples_ok -> return ()
	| Bad_response | Nonfatal_error | Fatal_error ->
	  execute_failed uri q r#error
	| _ ->
	  miscommunication uri q "Expected Tuples_ok or an error response."
	end

      let exec_prepared params q =
	use begin fun c ->
	  match q with
	  | Oneshot sql -> c#exec_io ~params sql
	  | Prepared pp -> c#exec_prepared_io ~params pp
	end

      let exec q params =
	exec_prepared params q >>= check_command_ok q

      let find q params =
	exec_prepared params q >>= fun r ->
	check_tuples_ok q r >>= fun () ->
	if r#ntuples = 0 then return None else
	if r#ntuples = 1 then return (Some (0, r)) else
	miscommunication uri q
			 "Received %d tuples, expected at most one." r#ntuples

      let fold q f params acc =
	exec_prepared params q >>= fun r ->
	check_tuples_ok q r >>= fun () ->
	let n = r#ntuples in
	let rec loop i acc =
	  if i = n then acc else
	  loop (i + 1) (f (i, r) acc) in
	return (loop 0 acc)

      let fold_s q f params acc =
	exec_prepared params q >>= fun r ->
	check_tuples_ok q r >>= fun () ->
	let n = r#ntuples in
	let rec loop i acc =
	  if i = n then return acc else
	  f (i, r) acc >>= loop (i + 1) in
	loop 0 acc

      let iter_s q f params =
	exec_prepared params q >>= fun r ->
	check_tuples_ok q r >>= fun () ->
	let a = r#get_all in
	let n = Array.length a in
	let rec loop i =
	  if i = n then return () else
	  f (i, r) >>= fun () -> loop (i + 1) in
	loop 0

      let iter_p q f params =
	exec_prepared params q >>= fun r ->
	check_tuples_ok q r >>= fun () ->
	let n = r#ntuples in
	let rec loop i =
	  if i = n then return () else
	  f (i, r) >>= fun () -> loop (i + 1) in (* FIXME: <&> *)
	loop 0

      module Param = Param
      module Tuple = Tuple
    end : CONNECTION)

end (* Make *)
end (* Connect_functor *)

let register () = Cardinal.register_scheme "postgresql" (module Connect_functor)
let () = register ()
