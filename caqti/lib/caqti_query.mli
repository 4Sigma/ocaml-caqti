(* Copyright (C) 2019--2023  Petter A. Urkedal <paurkedal@gmail.com>
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

(** Query specification. *)

type t =
  | L of string (** Literal code. May contain incomplete fragments. *)
  | V : 'a Caqti_type.Field.t * 'a -> t
                (** [V (t, v)] embeds the constant value [v : 'a] given its
                    field type [t : 'a Caqti_type.t].  This allows you to take
                    advantage of the driver-dependent conversions and escaping
                    mechanisms when embedding constants in a query. *)
  | Q of string (** [Q s] corresponds to a [TEXT] literal; passed as part of the
                    query string if a suitable quoting function is available in
                    the client library, otherwise passed as an additional
                    parameter. *)
  | P of int    (** [P i] refers to parameter number [i], counting from 0. *)
  | E of string (** [E name] is expanded by the environemnt lookup function. *)
  | S of t list (** [S frags] is the concatenation of [frags]. *)
(** A representation of a query string to send to a database, abstracting over
    parameter references and providing nested concatenation to simplify
    generation.  For databases which only support linear parameters (typically
    denoted "[?]"), the driver will reshuffle, elide, and duplicate parameters
    as needed.

    Additional constructors may be added to this type across minor releases. *)

val normal : t -> t
(** [normal q] rewrites [q] to a normal form containing at most one top-level
    {!S} constructor, containing no empty literals, and no consecutive literals.
    This function can be used to post-process queries before using {!equal} and
    {!hash}. *)

val equal : t -> t -> bool
(** Equality predicate for {!t}. *)

val hash : t -> int
(** A hash function compatible with {!equal}.  The hash function may change
    across minor versions and may depend on architecture. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf q] prints a {e human}-readable representation of [q] on [ppf].
    The printed string is {e not suitable for sending to an SQL database}; doing
    so may lead to an SQL injection vulnerability. *)

val show : t -> string
(** [show q] is the same {e human}-readable representation of [q] as printed by
    {!pp}.
    The returned string is {e not suitable for sending to an SQL database};
    doing so may lead to an SQL injection vulnerability. *)

val concat : string -> t list -> t
(** [concat sep frags] is [frags] interfixed with [sep] if [frags] is non-empty
    and the empty string of [frags] is empty. *)

type expand_error
(** A description of the error caused during {!expand} if the environment lookup
    function returns an invalid result or raises [Not_found] for a variable when
    the expansion is final. *)

val pp_expand_error : Format.formatter -> expand_error -> unit
(** Prints an informative error. *)

exception Expand_error of expand_error
(** The exception raised by {!expand} when there are issues expanding an
    environment variable using the provided callback. *)

val expand : ?final: bool -> (string -> t) -> t -> t
(** [expand f q] replaces each occurrence of [E v] some some [v] with [f v] or
    leaves it unchanged where [f v] raises [Not_found]. The [Not_found]
    exception will not escape this call.

    @param final
      If [true], then an error is raised instead of leaving environment
      references unexpended if [f] raises [Not_found].  This is used by drivers
      for performing the final expansion.  Defaults to [false].

    @raise Expand_error
      if [~final:true] is passed and [f] raise [Not_found] or if [f] returns a
      query containing environment references. *)

val angstrom_parser : t Angstrom.t
(** Matches a single expression terminated by the end of input or a semicolon
    lookahead. The accepted languages is described in {{!query_template} The
    Syntax of Query Templates}. *)

val angstrom_parser_with_semicolon : t Angstrom.t
(** A variant of [angstrom_parser] which accepts unquoted semicolons as part of
    the a statement, which is allowed in some cases like for defining SQLite3
    triggers.  This is the parser used by {!Caqti_request}, where it's assumed
    that the input is a single SQL statement. *)

val of_string : string -> (t, [`Invalid of int * string]) result
(** Parses a single expression using {!angstrom_parser_with_semicolon}.  The
    error indicates the byte position of the input string where the parse
    failure occurred in addition to an error message. See {{!query_template} The
    Syntax of Query Templates} for how the input string is interpreted. *)

val of_string_exn : string -> t
(** Like {!of_string}, but raises an exception on error.

    @raise Failure if parsing failed. *)

(**/**)
val qprintf : ('a, Format.formatter, unit, t) format4 -> 'a
[@@alert deprecated "Moved to Caqti_query_fmt."]
val kqprintf : (t -> 'a) -> ('b, Format.formatter, unit, 'a) format4 -> 'b
[@@alert deprecated "Moved to Caqti_query_fmt."]
val param : Format.formatter -> int -> unit
[@@alert deprecated "Moved to Caqti_query_fmt."]
val env : Format.formatter -> string -> unit
[@@alert deprecated "Moved to Caqti_query_fmt."]
val quote : Format.formatter -> string -> unit
[@@alert deprecated "Moved to Caqti_query_fmt."]
val query : Format.formatter -> t -> unit
[@@alert deprecated "Moved to Caqti_query_fmt."]
