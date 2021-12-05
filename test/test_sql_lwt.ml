(* Copyright (C) 2018--2021  Petter A. Urkedal <paurkedal@gmail.com>
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

open Lwt.Infix

open Caqti_common_priv
open Testkit

module Ground = struct

  type 'a future = 'a Lwt.t
  let return = Lwt.return
  let or_fail = Caqti_lwt.or_fail
  let (>>=) = Lwt.(>>=)
  let (>|=) = Lwt.(>|=)

  module Caqti_sys = Caqti_lwt

  module Alcotest = Testkit.Make_alcotest (Alcotest.Unix_platform) (Lwt)

end

module Test = Test_sql.Make (Ground)

let mk_test (name, pool) =
  let pass_conn pool (name, speed, f) =
    let f' () =
      Caqti_lwt.Pool.use (fun c -> Lwt_result.ok (f c)) pool >|= function
       | Ok () -> ()
       | Error err -> Alcotest.failf "%a" Caqti_error.pp err
    in
    (name, speed, f')
  in
  let pass_pool pool (name, speed, f) = (name, speed, (fun () -> f pool)) in
  let test_cases =
    List.map (pass_conn pool) Test.connection_test_cases @
    List.map (pass_pool pool) Test_parallel_lwt.test_cases @
    List.map (pass_conn pool) Test_param.test_cases @
    List.map (pass_pool pool) Test.pool_test_cases
  in
  (name, test_cases)

let mk_tests uris =
  let connect_pool uri =
    (match Caqti_lwt.connect_pool
              ~max_size:16 ~post_connect:Test.post_connect uri with
     | Ok pool -> (test_name_of_uri uri, pool)
     | Error err -> raise (Caqti_error.Exn err))
  in
  let pools = List.map connect_pool uris in
  List.map mk_test pools

let () = Lwt_main.run begin
  Ground.Alcotest.run_with_args_dependency "test_sql_lwt"
    Testkit.common_args mk_tests
end
