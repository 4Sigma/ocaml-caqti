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

open Caqti_describe
open Caqti_query
open Printf

let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)

module Q = struct

  let _q sql = prepare_fun @@ function
    | `Pgsql ->
      let i = ref 1 and buf = Buffer.create (String.length sql + 8) in
      String.iter
	(function '?' -> bprintf buf "$%d" !i; i := succ !i
		| c -> Buffer.add_char buf c)
	sql;
      Buffer.contents buf
    | `Sqlite -> sql
    | _ -> failwith "Unimplemented."

  let select_and = _q "SELECT ? AND ?"
  let select_plus_int = prepare_fun @@ function
    | `Pgsql -> "SELECT $1::integer + $2::integer"
    | `Sqlite -> "SELECT ? + ?"
    | _ -> failwith "Unimplemented."
  let select_plus_float = prepare_fun @@ function
    | `Pgsql -> "SELECT $1::float + $2::float"
    | `Sqlite -> "SELECT ? + ?"
    | _ -> failwith "Unimplemented."
  let select_cat = _q "SELECT ? || ?"

  let create_tmp = prepare_fun @@ function
    | `Pgsql -> "CREATE TEMPORARY TABLE caqti_test \
		 (id SERIAL NOT NULL, i INTEGER NOT NULL, s TEXT NOT NULL)"
    | `Sqlite -> "CREATE TABLE caqti_test \
		  (id INTEGER PRIMARY KEY, i INTEGRE NOT NULL, s TEXT NOT NULL)"
    | _ -> failwith "Unimplemented."
  let insert_into_tmp = prepare_fun @@ function
    | `Pgsql -> "INSERT INTO caqti_test (i, s) VALUES ($1, $2)"
    | `Sqlite -> "INSERT INTO caqti_test (i, s) VALUES (?, ?)"
    | _ -> failwith "Unimplemented."
  let select_from_tmp = prepare_fun @@ function
    | `Pgsql | `Sqlite -> "SELECT i, s FROM caqti_test"
    | _ -> failwith "Unimplemented."

end

let test_expr (module Db : Caqti_lwt.CONNECTION) =

  (* Non-prepared. *)
  for_lwt i = 0 to 199 do
    let qs = sprintf "SELECT %d, '%s'" i (string_of_int i) in
    match_lwt
      Db.find (Oneshot qs) Db.Tuple.(fun u -> int 0 u, text 1 u) [||]
    with
    | None -> assert false
    | Some (j, s) ->
      assert (i = j);
      assert (i = int_of_string s);
      Lwt.return_unit
  done >>

  (* Prepared: bool *)
  let ck_and a b =
    match_lwt
      Db.find Q.select_and
	      Db.Tuple.(fun u -> bool 0 u) Db.Param.([|bool a; bool b|])
    with
    | None -> assert false
    | Some c -> assert (c = (a && b)); Lwt.return_unit in
  ck_and false false >> ck_and false true >>
  ck_and true  false >> ck_and true  true >>

  (* Prepared: int *)
  let ck_plus_int i j =
    match_lwt
      Db.find Q.select_plus_int
	      Db.Tuple.(fun u -> int 0 u) Db.Param.([|int i; int j|])
    with
    | None -> assert false
    | Some k -> assert (k = (i + j)); Lwt.return_unit in
  for_lwt m = 0 to 199 do
    let i, j = Random.int (1 lsl 29), Random.int (1 lsl 29) in
    ck_plus_int i j
  done >>

  (* Prepared: int64 *)
  let ck_plus_int64 i j =
    match_lwt
      Db.find Q.select_plus_int
	      Db.Tuple.(fun u -> int64 0 u) Db.Param.([|int64 i; int64 j|])
    with
    | None -> assert false
    | Some k -> assert (k = Int64.add i j); Lwt.return_unit in
  for_lwt m = 0 to 199 do
    let i = Random.int64 Int64.(shift_left one 29) in
    let j = Random.int64 Int64.(shift_left one 29) in
    ck_plus_int64 i j
  done >>

  (* Prepared: float *)
  let ck_plus_float x y =
    match_lwt
      Db.find Q.select_plus_float
	      Db.Tuple.(fun u -> float 0 u) Db.Param.([|float x; float y|])
    with
    | None -> assert false
    | Some z ->
      assert (abs_float (z -. (x +. y)) < 1e-8 *. (x +. y));
      Lwt.return_unit in
  for_lwt m = 0 to 199 do
    let i, j = Random.float 1e8, Random.float 1e8 in
    ck_plus_float i j
  done >>

  (* Prepared: string *)
  let ck_string x y =
    match_lwt
      Db.find Q.select_cat
	      Db.Tuple.(fun u -> text 0 u) Db.Param.([|text x; text y|])
    with
    | None -> assert false
    | Some s -> assert (s = x ^ y); Lwt.return_unit in
  for_lwt m = 0 to 199 do
    let x = sprintf "%x" (Random.int (1 lsl 29)) in
    let y = sprintf "%x" (Random.int (1 lsl 29)) in
    ck_string x y
  done

let test_table (module Db : Caqti_lwt.CONNECTION) =

  let is_typed = Uri.scheme Db.uri <> Some "sqlite3" in

  (* Create, insert, select *)
  Db.exec Q.create_tmp [||] >>
  Db.exec Q.insert_into_tmp Db.Param.([|int 2; text "two"|]) >>
  Db.exec Q.insert_into_tmp Db.Param.([|int 3; text "three"|]) >>
  Db.exec Q.insert_into_tmp Db.Param.([|int 5; text "five"|]) >>
  lwt (i_acc, s_acc) = Db.fold Q.select_from_tmp
    Db.Tuple.(fun t (i_acc, s_acc) -> (i_acc + int 0 t, s_acc ^ "+" ^ text 1 t))
    [||] (0, "zero") in
  assert (i_acc = 10);
  assert (s_acc = "zero+two+three+five");

  (* Describe *)
  if is_typed then begin
    lwt qd = Db.describe Q.select_from_tmp in
    assert (qd.querydesc_params = [||]);
    assert (qd.querydesc_fields = [|"i", `Int; "s", `Text|]);
    Lwt.return_unit
  end else Lwt.return_unit

let test (module Db : Caqti_lwt.CONNECTION) =
  test_expr (module Db) >>
  test_table (module Db) >>
  Db.drain ()

let () =
  (* Needed for bytecode as plugins link against C libraries. *)
  Dynlink.allow_unsafe_modules true;

  let uri_r = ref None in
  Arg.parse
    [ "-u", Arg.String (fun s -> uri_r := Some (Uri.of_string s)),
	"URI Test against URI."; ]
    (fun _ -> raise (Arg.Bad "No positional arguments expected."))
    Sys.argv.(0);
  let uri =
    match !uri_r with
    | None -> Uri.of_string "sqlite3:"
    | Some uri -> uri in
  Lwt_main.run (Caqti_lwt.connect uri >>= test)
