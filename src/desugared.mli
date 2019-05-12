(** Desugared syntax of Coop. *)

type signature = {
    sig_ops : Name.Set.t ;
    sig_sgs : Name.Set.t
  }

(** Types. *)
type ty = ty' Location.located
and ty' =
  | Int
  | Bool
  | Arrow of ty * ty
  | Product of ty list
  | ComodelTy of Name.Set.t * ty * signature
  | CompTy of ty * signature

(** Patterns *)
type pattern = pattern' Location.located
and pattern' =
  | PattAnonymous
  | PattVar of Name.t
  | PattNumeral of int
  | PattBoolean of bool
  | PattTuple of pattern list

(** Expressions *)
type expr = expr' Location.located
and expr' =
  | AscribeExpr of expr * ty
  | Var of Name.t
  | Numeral of int
  | Boolean of bool
  | Tuple of expr list
  | Lambda of binder * comp
  | Comodel of ty * comodel_clause list

(** Computations *)
and comp = comp' Location.located
and comp' =
  | AscribeComp of comp * ty
  | Val of expr
  | Let of pattern * comp * comp
  | Match of expr * (binder * comp) list
  | Apply of expr * expr
  | Operation of Name.t * expr
  | Signal of Name.t * expr
  | Using of expr * expr * comp * finally

and binder = pattern * ty option

and comodel_clause = Name.t * binder * binder * comp

and finally = {
    fin_val : binder * binder * comp ;
    fin_signals : (Name.t * binder * binder * comp) list
  }

(** Top-level commands. *)
type toplevel = toplevel' Location.located
and toplevel' =
  | TopLoad of toplevel list
  | TopLet of pattern * comp
  | TopComp of comp
  | DeclOperation of Name.t * ty * ty
  | DeclSignal of Name.t * ty
  | External of Name.t * ty * string
