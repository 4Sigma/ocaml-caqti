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

(** Signatures. *)

open Caqti_describe
open Caqti_query

(** The main API as provided after connecting to a resource. *)
module type CONNECTION = sig

  type 'a io
  (** The IO monad for which the module is specialized. *)

  type param
  (** An abstract type for a query parameter.  Only the backend knows the
      actual type. *)

  type tuple
  (** An abstract type for a tuple passed by a backend to callbacks during
      query execution. *)

  val uri : Uri.t
  (** The connected URI. *)

  val drain : unit -> unit io
  (** Close all open connections.  For pooled connections, the pool is
      drained.  For single connections, the connection is closed.  For
      backends which reconnects on each query, this does nothing.

      {b Note!} Not implemented yet for pooled connections. *)

  val describe : query -> querydesc io
  (** Returns a description of parameters and returned tuples.  What is
      returned may be limited by what the underlying library supports.  The
      number of paratemers and tuple components should be correct, but the
      types may be [`Unknown]. *)

  (** {3 Querying } *)

  val exec : query -> param array -> unit io
  (** [exec q params] executes a query [q(params)] which is not expected to
      return anything. *)

  val find : query -> (tuple -> 'a) -> param array -> 'a option io
  (** [find q params] executes a query [q(params)] which is expected to return
      at most one tuple. *)

  val fold : query -> (tuple -> 'a -> 'a) -> param array -> 'a -> 'a io
  (** [fold q f params acc] executes [q(params)], composes [f] over the
      resulting tuples in order, and applies the composition to [acc]. *)

  val fold_s : query -> (tuple -> 'a -> 'a io) -> param array -> 'a -> 'a io
  (** [fold_s q f params acc] executes [q(params)], forms a threaded
      composition of [f] over the resulting tuples, and applies the
      composition to [acc]. *)

  val iter_p : query -> (tuple -> unit io) -> param array -> unit io
  (** [fold_p q f params] executes [q(params)] and calls [f t] in the thread
      monad in parallel for each resulting tuple [t].  A certain backend may
      not implement parallel execution, in which case this is the same as
      {!iter_s}. *)

  val iter_s : query -> (tuple -> unit io) -> param array -> unit io
  (** [fold_s q f params] executes [q(params)] and calls [f t] sequentially in
      the thread monad for each resulting tuple [t] in order. *)

  (** {3 Parameter and Tuple Coding} *)

  (** Parameter encoding functions. *)
  module Param : sig
    val null : param
    (** For SQL, [null] is [NULL]. *)

    val option : ('a -> param) -> 'a option -> param
    (** [option f None] is [null] and [option f (Some x)] is [f x]. *)

    val bool : bool -> param
    (** Constructs a boolean parameter. *)

    val int : int -> param
    (** Constructs an integer parameter. The remote end may have a different
	range. For SQL, works with all integer types. *)

    val int64 : int64 -> param
    (** Constructs an integer parameter. The remote end may have a different
	range. For SQL, works with all integer types. *)

    val float : float -> param
    (** Constructs a floating point parameter. The precision of the storage
	may be different from that of the OCaml [float]. *)

    val text : string -> param
    (** Given an UTF-8 encoded text, constructs a textual parameter with
	backend-specific encoding. *)

    val octets : string -> param
    (** Constructs a parameter from an arbitrary [string].  For SQL, the
	parameter is compatible with the [BINARY] type. *)

    val date : CalendarLib.Date.t -> param
    (** Construct a parameter representing a date. *)

    val utc : CalendarLib.Calendar.t -> param
    (** Construct a parameter representing an UTC time value.  Selecting a
	time zone suitable for an end-user is left to the application. *)

    val other : string -> param
    (** A backend-specific value. *)
  end

  (** Tuple decoding functions.

      These functions extracts and decodes components from a returned tuple.
      The first argument is the index, starting from 0.  The conversion
      performed are the inverse of the same named function of {!Param}, so the
      documentation is not repeated here.

      {b Note!}  Calls to these functions are only valid during a callback
      from one of the query execution functions.  Returning a partial call or
      embedding the call in a returned monad leads to undefined behaviour. *)
  module Tuple : sig
    val is_null : int -> tuple -> bool
    val option : (int -> tuple -> 'a) -> int -> tuple -> 'a option
    val bool : int -> tuple -> bool
    val int : int -> tuple -> int
    val int64 : int -> tuple -> int64
    val float : int -> tuple -> float
    val text : int -> tuple -> string
    val octets : int -> tuple -> string
    val date : int -> tuple -> CalendarLib.Date.t
    val utc : int -> tuple -> CalendarLib.Calendar.t
    val other : int -> tuple -> string
  end

end

(** The connect function along with its first-class module signature. *)
module type CONNECT = sig
  type 'a io
  module type CONNECTION = CONNECTION with type 'a io = 'a io
  val connect : ?max_pool_size: int -> Uri.t -> (module CONNECTION) io
end

(** The IO monad and system utilities used by backends.  Note that this
    signature will likely be extended due requirements of new backends. *)
module type SYSTEM = sig

  type 'a io
  val (>>=) : 'a io -> ('a -> 'b io) -> 'b io
  val return : 'a -> 'a io
  val fail : exn -> 'a io
  val join : unit io list -> unit io

  module Unix : sig
    type file_descr
    val of_unix_file_descr : Unix.file_descr -> file_descr
    val wait_read : file_descr -> unit io
  end

  module Pool : sig
    type 'a t
    val create : ?max_size: int -> ?max_priority: int ->
		 ?validate: ('a -> bool io) -> (unit -> 'a io) -> 'a t
    val use : ?priority: int -> ('a -> 'b io) -> 'a t -> 'b io
    val drain : 'a t -> unit io
  end

  module Log : sig
    val error_f : query -> ('a, unit, string, unit io) format4 -> 'a
    val warning_f : query -> ('a, unit, string, unit io) format4 -> 'a
    val info_f : query -> ('a, unit, string, unit io) format4 -> 'a
    val debug_f : query -> ('a, unit, string, unit io) format4 -> 'a
  end

  module Preemptive : sig
    val detach : ('a -> 'b) -> 'a -> 'b io
    val run_in_main : (unit -> 'a io) -> 'a
  end

end

(** Abstraction of the connect function over the concurrency monad. *)
module type CONNECT_FUNCTOR = sig
  module Make (System : SYSTEM) : CONNECT with type 'a io = 'a System.io
end
