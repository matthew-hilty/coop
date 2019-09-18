(** Support for pretty-printing and user messages. *)

(** Print a message with given verbosity level. *)
let message ~verbosity =
  if verbosity <= !Config.verbosity then
    fun fmt -> Format.eprintf (fmt ^^ "@.")
  else
    Format.ifprintf Format.err_formatter

(** Report an error. *)
let error fmt = message ~verbosity:1 fmt

(** Report a warning. *)
let warning fmt = message ~verbosity:2 fmt

(** Print an expression, possibly parenthesized. *)
let print ?(at_level=Level.no_parens) ?(max_level=Level.highest) ppf =
  if Level.parenthesize ~at_level ~max_level then
    fun fmt -> Format.fprintf ppf ("(" ^^ fmt ^^ ")")
  else
    Format.fprintf ppf

(** Print a sequence with given separator and printer. *)
let sequence print_u separator us ppf =
  match us with
    | [] -> ()
    | [u] -> print_u u ppf
    | u :: ((_ :: _) as us) ->
      print_u u ppf ;
      List.iter (fun u -> print ppf "%s@ " separator ; print_u u ppf) us

(** Print a set of names as a sequence *)
let names ns ppf =
  let ns = List.sort Stdlib.compare (Name.Set.elements ns) in
  sequence (Name.print ~parentheses:true) "," ns ppf

(** Unicode and ascii versions of symbols. *)

let select ascii utf = if !Config.ascii then ascii else utf

let char_arrow () = select "->" "→"
let char_prearrow () = select "-{" "-{"
let char_postarrow () = select "}->" "}→"

let char_darrow () = select "=>" "⇒"
let char_times () = select "*" "×"

let char_lightning () = select "!!" "↯"
