(* Copyright (C) 2022  Petter A. Urkedal <paurkedal@gmail.com>
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

(** Concurrent stream signature. *)

module type S = sig
  type +'a fiber

  type ('a, 'err) t = unit -> ('a, 'err) node fiber
  (** A stream, represented as a lazy chain of {!Cons}-nodes terminating in a
      {!Nil} or an {!Error}. *)

  and ('a, 'err) node =
    | Nil                       (** The node of an empty stream *)
    | Error of 'err             (** A node of a permanently failed stream. *)
    | Cons of 'a * ('a, 'err) t
        (** A node holding the next element and continuation of a stream. *)

  val fold :
    f: ('a -> 'state -> 'state) ->
    ('a, 'err) t ->
    'state ->
    ('state, 'err) result fiber
  (** [fold ~f stream acc] consumes the remainder elements [e1], ..., [eN] of
      [stream] and returns [Ok (acc |> f e1 |> ... |> f eN)] if no error
      occurred *)

  val fold_s :
    f: ('a -> 'state -> ('state, 'err) result fiber) ->
    ('a, 'clog) t ->
    'state ->
    ('state, [> `Congested of 'clog ] as 'err) result fiber
  (** [fold_s ~f stream acc] consumes the remainder of [stream], passing each
      element in order to [f] along with the latest accumulation starting at
      [acc], and returning the final accumulation if successful.  An error
      result may be due to either the stream provider or the callback, as
      distinguished with the [`Congested] constructor. *)

  val iter_s :
    f: ('a -> (unit, 'err) result fiber) ->
    ('a, 'clog) t ->
    (unit, [> `Congested of 'clog ] as 'err) result fiber
  (** [iter_s ~f stream] consumes the remainder of [stream], passing each
      element in order to [f].  An error result may be due to either the steram
      provider or the callback, as distinguished with the [`Congested]
      constructor. *)

  val to_rev_list : ('a, 'err) t -> ('a list, 'err) result fiber
  (** [to_rev_list stream] consumes the remainder of [stream], returning a list
      of its element in reverse order of production. *)

  val to_list : ('a, 'err) t -> ('a list, 'err) result fiber
  (** [to_list stream] consumes the remainder of [stream], returning a list of
      its element in order of production. *)

  val of_list : 'a list -> ('a, 'err) t
  (** [of_list xs] is a non-failing finite stream (re)producing the elements
      [xs] in order of occurrence. *)

  val map_result : f: ('a -> ('b, 'err) result) -> ('a, 'err) t -> ('b, 'err) t
end
