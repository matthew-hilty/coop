type environment = {
    env_vars : Value.t list ;
    env_container : Value.container
  }

type error =
  | InvalidDeBruijn of int
  | UnhandledOperation of Name.t
  | UnhandledSignal of Name.t
  | UnhandledException of Name.t
  | UnknownExternal of string
  | IllegalRenaming of Name.t
  | IllegalComparison of Value.t
  | FunctionExpected
  | RunnerExpected
  | RunnerDoubleOperation of Name.t
  | ContainerDoubleOperation of Name.t
  | PairExpected
  | ContainerExpected
  | PatternMismatch

exception Error of error Location.located

let error ~loc err = Stdlib.raise (Error (Location.locate ~loc err))

let print_error err ppf =
  match err with

  | InvalidDeBruijn i ->
     Format.fprintf ppf "invalid de Bruijn index %d, please report" i

  | UnhandledOperation op ->
     Format.fprintf ppf "unhandled operation %t"
       (Name.print op)

  | UnhandledSignal sgl ->
     Format.fprintf ppf "terminated by signal %t"
       (Name.print sgl)

  | UnhandledException exc ->
     Format.fprintf ppf "unhandled exception %t"
       (Name.print exc)

  | UnknownExternal s ->
     Format.fprintf ppf "unknown external %s" s

  | IllegalRenaming op ->
     Format.fprintf ppf "illegal runner renaming %t, please report" (Name.print op)

  | IllegalComparison v ->
     Format.fprintf ppf "cannot compare %s" (Value.names v)

  | FunctionExpected ->
     Format.fprintf ppf "function expected, please report"

  | RunnerExpected ->
     Format.fprintf ppf "runner expected, please report"

  | RunnerDoubleOperation op ->
     Format.fprintf ppf "cannot combine runners that both implement %t" (Name.print op)

  | ContainerDoubleOperation op ->
     Format.fprintf ppf "cannot combine containers that both implement %t" (Name.print op)

  | PairExpected ->
     Format.fprintf ppf "pair expected, please report"

  | ContainerExpected ->
     Format.fprintf ppf "container expected, please report"

  | PatternMismatch ->
     Format.fprintf ppf "pattern mismatch"

let initial = {
    env_vars = [] ;
    env_container = Value.pure_container
}

let set_container env_container env =
  { env with env_container }

(** Extend the variables with a variable *)
let extend_var v vars = v :: vars

let rec extend_vars vs vars =
  match vs with
  | [] -> vars
  | v :: vs ->
     let vars = extend_var v vars in
     extend_vars vs vars

let lookup_var ~loc i vars =
  try
    List.nth vars i
  with
  | Failure _ -> error ~loc (InvalidDeBruijn i)

let match_pattern p v =
  let rec fold us p v =
    match p with

    | Syntax.PattAnonymous -> Some us

    | Syntax.PattVar ->
       Some (v :: us)

    | Syntax.PattNumeral m ->
        begin match v with
        | Value.Numeral n when m = n -> Some us
        | _ -> None
        end

    | Syntax.PattBoolean b ->
       begin match v with
       | Value.Boolean b' when b = b' -> Some us
       | _ -> None
       end

    | Syntax.PattQuoted s ->
       begin match v with
       | Value.Quoted s' -> if String.equal s s' then Some us else None
       | _ -> None
       end

    | Syntax.PattConstructor (cnstr, popt) ->
       begin match v with
       | Value.Constructor (cnstr', vopt) when Name.equal cnstr cnstr' ->
          begin
           match popt, vopt with
           | None, None -> Some us
           | Some p, Some v -> fold us p v
           | Some _, None | None, Some _ -> None
          end
       | _ -> None
       end

    | Syntax.PattTuple ps ->
       begin match v with
       | Value.Tuple vs -> fold_tuple us ps vs
       | _ -> None
       end

  and fold_tuple us ps vs =
    match ps, vs with
    | [], [] -> Some us
    | p :: ps, v :: vs ->
       begin
         match fold us p v with
         | None -> None
         | Some us -> fold_tuple us ps vs
       end
    | [], _::_ | _::_, [] -> None
  in

  match fold [] p v with
  | None -> None
  | Some us -> Some (List.rev us)


let extend_pattern ~loc p v env =
  match match_pattern p v with
  | None -> error ~loc PatternMismatch
  | Some us -> extend_vars us env

let top_extend_pattern ~loc p v env =
  match match_pattern p v with
  | None -> error ~loc PatternMismatch
  | Some us -> extend_vars us env, us

let match_clauses ~loc env ps v =
  let rec fold = function
    | [] -> error ~loc PatternMismatch
    | (p, c) :: lst ->
       begin
         match match_pattern p v with
         | None -> fold lst
         | Some us -> (extend_vars us env, c)
       end
  in
  fold ps

let as_pair ~loc = function
  | Value.Tuple [v1; v2] -> (v1, v2)
  | Value.(ClosureUser _ | ClosureKernel _ | Numeral _ | Boolean _ | Quoted _ | Constructor _
    | Tuple ([] | [_] | _::_::_::_) | Runner _ | Abstract _ | Container _) ->
     error ~loc PairExpected

let as_closure_user ~loc = function
  | Value.ClosureUser f -> f
  | Value.(Numeral _ | Boolean _ | Quoted _ | Constructor _ | Tuple _ |
           ClosureKernel _ | Runner _  | Abstract _ | Container _) ->
     error ~loc FunctionExpected

let as_closure_kernel ~loc = function
  | Value.ClosureKernel f -> f
  | Value.(Numeral _ | Boolean _ | Quoted _ | Constructor _ | Tuple _ |
           ClosureUser _ | Runner _  | Abstract _ | Container _) ->
     error ~loc FunctionExpected

let as_runner ~loc = function
  | Value.Runner rnr -> rnr
  | Value.(Numeral _ | Boolean _ | Quoted _ | Tuple _ | Constructor _ |
           ClosureUser _  |ClosureKernel _ |  Abstract _ | Container _) ->
     error ~loc RunnerExpected

let as_container ~loc = function
  | Value.Container ops -> ops
  | Value.(Numeral _ | Boolean _ | Quoted _ | Tuple _ | Constructor _ |
           ClosureUser _  |ClosureKernel _ |  Abstract _ | Runner _) ->
     error ~loc ContainerExpected


(** Comparison of values *)
let rec equal_value ~loc (v1 : Value.t) (v2 : Value.t) =
  match v1, v2 with

  | Value.(Abstract (In_channel _ | Out_channel _) |
           ClosureUser _ | ClosureKernel _ | Runner _ | Container _), _ ->
     error ~loc (IllegalComparison v1)

  | _, Value.(Abstract (In_channel _ | Out_channel _) |
              ClosureUser _ | ClosureKernel _ | Runner _) ->
     error ~loc (IllegalComparison v1)

  | Value.(Numeral k1, Numeral k2) ->
     k1 = k2

  | Value.(Boolean b1, Boolean b2) ->
     b1 = b2

  | Value.(Quoted s1, Quoted s2) ->
     String.equal s1 s2

  | Value.(Constructor (cnstr1, v1opt), Constructor (cnstr2, v2opt)) ->
     Name.equal cnstr1 cnstr2 && equal_value_opt ~loc v1opt v2opt

 | (Value.Tuple lst1, Value.Tuple lst2) ->
    equal_values ~loc lst1 lst2

 | Value.(Numeral _ | Boolean _ | Quoted _ | Constructor _ | Tuple _), _ ->
    false

and equal_value_opt ~loc v1opt v2opt =
  match v1opt, v2opt with
  | None, None -> true
  | Some v1, Some v2 -> equal_value ~loc v1 v2
  | None, Some _ | Some _, None -> false

and equal_values ~loc vs1 vs2 =
  match vs1, vs2 with
  | [], [] -> true
  | v1 :: vs1, v2 :: vs2 -> equal_value ~loc v1 v2 && equal_values ~loc vs1 vs2
  | [], _::_ | _::_, [] -> false

(*** Auxiliary ***)

(** Exception handler part which reraises every expresions, user mode *)
let reraise_user excs =
  Name.Set.fold
  (fun exc m -> Name.Map.add exc (fun v -> Value.(UserException (Exception (exc, v)))) m)
  excs
  Name.Map.empty

(** Exception handler part which reraises every expresions, kernel mode *)
let reraise_kernel w excs =
  Name.Set.fold
    (fun exc m -> Name.Map.add exc (fun v -> Value.(KernelException (Exception (exc, v), w))) m)
    excs
    Name.Map.empty

(** Lookup an exception, to be used in a [with] clause. *)
let lookup_with_exception excs exc =
  Name.Map.find exc excs

(** Lookup an exception, to be used in a [finally clause] *)
let lookup_finally_exception ~loc excs exc =
  match Name.Map.find exc excs with
  | None -> error ~loc (UnhandledException exc)
  | Some f -> f

let lookup_signal ~loc sgns sgn =
  match Name.Map.find sgn sgns with
  | None -> error ~loc (UnhandledSignal sgn)
  | Some f -> f

let lookup_operation ~loc ops op =
  match Name.Map.find op ops with
  | None -> error ~loc (UnhandledOperation op)
  | Some f -> f


(*** Evaluation ***)
let user_return = Value.user_return
let (>>=) = Value.user_bind

let kernel_return = Value.kernel_return
let (>>=!) = Value.kernel_bind

let rec eval_expr env {Location.it=e'; loc} =
  match e' with

  | Syntax.Numeral k -> Value.Numeral k

  | Syntax.Boolean b -> Value.Boolean b

  | Syntax.Quoted s -> Value.Quoted s

  | Syntax.Var i -> lookup_var ~loc i env

  | Syntax.Constructor (cnstr, None) ->
     Value.Constructor (cnstr, None)

  | Syntax.Constructor (cnstr, Some e) ->
     let v = eval_expr env e in
     Value.Constructor (cnstr, Some v)

  | Syntax.Tuple lst ->
     let lst = List.map (eval_expr env) lst in
     Value.Tuple lst

  | Syntax.FunUser (p, c) ->
     let f v =
       let env = extend_pattern ~loc p v env in
       eval_user env c
     in
     Value.(ClosureUser f)

  | Syntax.FunKernel (p, c) ->
     let f v =
       let env = extend_pattern ~loc p v env in
       eval_kernel env c
     in
     Value.(ClosureKernel f)

  | Syntax.Runner lst ->
     let coop px c =
       let loc = c.Location.loc in
       fun u ->
       let env = extend_pattern ~loc px u env in
       eval_kernel env c
     in
     let rnr =
       List.fold_left
         (fun rnr (op, px, c) -> Name.Map.add op (coop px c) rnr)
         Name.Map.empty
         lst
     in
     Value.(Runner rnr)

  | Syntax.RunnerTimes (e1, e2) ->
     let wrap lens_get lens_put coop v w =
       let rec fold = function
       | Value.KernelVal (v, w'') -> Value.KernelVal (v, lens_put w w'')
       | Value.KernelException (e, w'') -> Value.KernelException (e, lens_put w w'')
       | Value.KernelSignal _ as s -> s
       | Value.KernelOperation (op, u, l_return, l_exc) ->
          let l_return v = fold (l_return v)
          and l_exc = Name.Map.map (fun f v -> fold (f v)) l_exc in
          Value.KernelOperation (op, u, l_return, l_exc)
       in
       let w' = lens_get w in
       fold (coop v w')
     in
     let rnr1 = as_runner ~loc (eval_expr env e1)
     and rnr2 = as_runner ~loc (eval_expr env e2) in
     let rnr =
       Name.Map.merge
         (fun op f1 f2 ->
           match f1, f2 with
           | None, None -> None
           | Some f1, None ->
              let lens_get (Value.World w) =
                let (w1, _) = as_pair ~loc w in Value.World w1
              and lens_put (Value.World w) (Value.World w1) =
                let (_, w2) = as_pair ~loc w in Value.World (Value.Tuple [w1; w2])
              in
              Some (wrap lens_get lens_put f1)
           | None, Some f2 ->
              let lens_get (Value.World w) =
                let (_, w2) = as_pair ~loc w in Value.World w2
              and lens_put (Value.World w) (Value.World w2) =
                let (w1, _) = as_pair ~loc w in Value.World (Value.Tuple [w1; w2])
              in
              Some (wrap lens_get lens_put f2)
           | Some _, Some _ -> error ~loc (RunnerDoubleOperation op))
         rnr1 rnr2
     in
     Value.Runner rnr

  | Syntax.RunnerRename (e, rnm) ->
     let rnr = as_runner ~loc (eval_expr env e) in
     let rnr =
       Name.Map.fold
         (fun op f rnr ->
           match Name.Map.find op rnm with
           | None -> error ~loc (IllegalRenaming op)
           | Some op' -> Name.Map.add op' f rnr)
         rnr Name.Map.empty
     in
     Value.Runner rnr

and eval_user env Location.{it=c'; loc} =
  match c' with

  | Syntax.UserVal e ->
     let v = eval_expr env e in
     user_return v

  | Syntax.UserMatch (e, lst) ->
     let v = eval_expr env e in
     let env, c = match_clauses ~loc env lst v in
     eval_user env c

  | Syntax.UserEqual (e1, e2) ->
     let v1 = eval_expr env e1
     and v2 = eval_expr env e2 in
     let b = equal_value ~loc v1 v2 in
     user_return (Value.Boolean b)

  | Syntax.UserApply (e1, e2) ->
     let v1 = eval_expr env e1 in
     let f = as_closure_user ~loc v1 in
     let v2 = eval_expr env e2 in
     f v2

  | Syntax.UserLet (p, c1, c2) ->
     eval_user env c1 >>= fun v ->
     eval_user (extend_pattern ~loc p v env) c2

  | Syntax.UserLetRec (fs, c) ->
     let env = extend_rec ~loc fs env in
     eval_user env c

  | Syntax.(UserOperation (op, u, Exceptions excs)) ->
     let u = eval_expr env u in
     Value.UserOperation (op, u, user_return, reraise_user excs)

  | Syntax.UserRaise (exc, e) ->
     let v = eval_expr env e in
     Value.(UserException (Exception (exc, v)))

  | Syntax.UserUsing (rnr, w, c, fin) ->
     let rnr = as_runner ~loc (eval_expr env rnr)
     and w = eval_expr env w
     and fin = eval_finally ~loc env fin
     and r = eval_user env c in
     user_using ~loc rnr (Value.World w) r fin

  | Syntax.UserExec (c, w, fin) ->
     let fin = eval_finally ~loc env fin
     and w = Value.World (eval_expr env w)
     and r = eval_kernel env c in
     user_exec ~loc w r fin

  | Syntax.UserTry (c, hnd) ->
     let (exc_return, exc_raise) = eval_user_exception_handler ~loc env hnd in
     let rec fold = function

       | Value.UserVal v -> exc_return v

       | Value.(UserException (Exception (exc, v))) as e ->
          begin match lookup_with_exception exc_raise exc with
          | Some f -> f v
          | None -> e
          end

       | Value.UserOperation (op, v, f_return, f_exc) ->
          let f_return v = fold (f_return v)
          and f_exc = Name.Map.map (fun f v -> fold (f v)) f_exc in
          Value.UserOperation (op, v, f_return, f_exc)
     in
     let r = eval_user env c in
     fold r

and eval_kernel env Location.{it=c';loc} w =
  match c' with

  | Syntax.KernelVal e ->
     let v = eval_expr env e in
     kernel_return v w

  | Syntax.KernelMatch (e, lst) ->
     let v = eval_expr env e in
     let env, c = match_clauses ~loc env lst v in
     eval_kernel env c w

  | Syntax.KernelEqual (e1, e2) ->
     let v1 = eval_expr env e1
     and v2 = eval_expr env e2 in
     let b = equal_value ~loc v1 v2 in
     kernel_return (Value.Boolean b) w

  | Syntax.KernelApply (e1, e2) ->
     let v1 = eval_expr env e1 in
     let f = as_closure_kernel ~loc v1 in
     let v2 = eval_expr env e2 in
     f v2 w

  | Syntax.KernelLet (p, c1, c2) ->
     (eval_kernel env c1 >>=! fun v ->
      eval_kernel (extend_pattern ~loc p v env) c2) w

  | Syntax.KernelLetRec (fs, c) ->
     let env = extend_rec ~loc fs env in
     eval_kernel env c w

  | Syntax.(KernelOperation (op, u, Exceptions excs)) ->
     let u = eval_expr env u in
     Value.KernelOperation (op, u, (fun v -> kernel_return v w), reraise_kernel w excs)

  | Syntax.KernelRaise (exc, e) ->
     let v = eval_expr env e in
     Value.(KernelException (Exception (exc, v), w))

  | Syntax.KernelKill  (sgn, e) ->
     let v = eval_expr env e in
     Value.(KernelSignal (Signal (sgn, v)))

  | Syntax.KernelExec (c, hnd) ->
     let (h_return, h_exc) = eval_kernel_exception_handler ~loc env hnd in
     let rec fold = function
       | Value.UserVal v -> h_return v w

       | Value.(UserException (Exception (exc, v) as e)) ->
          begin match lookup_with_exception h_exc exc with
          | Some f -> f v w
          | None -> Value.(KernelException (e, w))
          end

       | Value.UserOperation (op, v, f_return, f_exc) ->
          let f_return v = fold (f_return v)
          and f_exc = Name.Map.map (fun f v -> fold (f v)) f_exc in
          Value.KernelOperation (op, v, f_return, f_exc)
     in
     let r = eval_user env c in
     fold r

  | Syntax.KernelTry (c, hnd) ->
     let (exc_return, exc_raise) = eval_kernel_exception_handler ~loc env hnd in
     let rec fold = function

       | Value.KernelVal (v, w) -> exc_return v w

       | Value.(KernelException (Exception (exc, v), w)) as e ->
          begin match lookup_with_exception exc_raise exc with
          | Some f -> f v w
          | None ->  e
          end

       | Value.KernelSignal _ as r ->
          r

       | Value.KernelOperation (op, v, f_return, f_exc) ->
          let f_return v = fold (f_return v)
          and f_exc = Name.Map.map (fun f v -> fold (f v)) f_exc in
          Value.KernelOperation (op, v, f_return, f_exc)
     in
     let r = eval_kernel env c w in
     fold r

  | Syntax.KernelGetenv ->
     let Value.World v = w in
     Value.KernelVal (v, w)

  | Syntax.KernelSetenv e ->
     let v = eval_expr env e in
     Value.(KernelVal (unit_val, Value.World v))

and eval_user_exception_handler ~loc env Syntax.{try_return; try_raise} =
  let f_return v =
    match try_return with
    | Some (px,c) -> let env = extend_pattern ~loc px v env in eval_user env c
    | None -> Value.user_return v
  and f_excs =
    List.fold_left
    (fun m (exc, px, c) ->
      let f_exc v = (let env = extend_pattern ~loc px v env in eval_user env c) in
      Name.Map.add exc f_exc m)
    Name.Map.empty
    try_raise
  in
  (f_return, f_excs)

and eval_kernel_exception_handler ~loc env Syntax.{try_return; try_raise} =
  let f_return v =
    match try_return with
    | Some (px,c) -> let env = extend_pattern ~loc px v env in eval_kernel env c
    | None -> Value.kernel_return v
  and f_excs =
    List.fold_left
    (fun m (exc, px, c) ->
      let f_exc v = (let env = extend_pattern ~loc px v env in eval_kernel env c) in
      Name.Map.add exc f_exc m)
    Name.Map.empty
    try_raise
  in
  (f_return, f_excs)

and eval_finally ~loc env Syntax.{fin_return=(px, pw, c); fin_raise; fin_kill} =
  let fin_return (v, Value.World w) =
    let env = extend_pattern ~loc px v env in
    let env = extend_pattern ~loc pw w env in
    eval_user env c
  and fin_raise =
    List.fold_left
      (fun fin_raise (exc, px, pw, c) ->
        let f (v, Value.World w) =
          let env = extend_pattern ~loc px v env in
          let env = extend_pattern ~loc pw w env in
          eval_user env c
        in
        Name.Map.add exc f fin_raise)
      Name.Map.empty
      fin_raise
  and fin_kill =
    List.fold_left
      (fun fin_kill (sgn, px, c) ->
        let f v =
          let env = extend_pattern ~loc px v env in
          eval_user env c
        in
        Name.Map.add sgn f fin_kill)
      Name.Map.empty
      fin_kill
  in
  (fin_return, fin_raise, fin_kill)

and extend_rec ~loc fs env =
  let env' = ref env in
  let mk_closure = function
    | Syntax.RecUser (p, c) -> Value.ClosureUser (fun v -> eval_user (extend_pattern ~loc p v !env') c)
    | Syntax.RecKernel (p, c) -> Value.ClosureKernel (fun v -> eval_kernel (extend_pattern ~loc p v !env') c)
  in
  let fs = List.map mk_closure fs in
  let env = extend_vars fs env in
  env' := env ;
  env

(** Run a result with the given runner and finally clause. *)
and user_using ~loc rnr w r (fin_return, fin_raise, fin_kill) =
  let rec using w = function
    | Value.UserVal v ->
       fin_return (v, w)

    | Value.(UserException (Exception (exc, v))) ->
       let f_exc = lookup_finally_exception ~loc fin_raise exc in
       f_exc (v, w)

    | Value.UserOperation (op, v, f_return, f_exc) ->
       let coop = lookup_operation ~loc rnr op in
       let f_return (v, w) = (let r = f_return v in using w r)
       and f_exc = Name.Map.map (fun f -> (fun (v, w) -> using w (f v))) f_exc
       in
       user_exec ~loc w (coop v) (f_return, f_exc, fin_kill)
  in
  using w r

and user_exec ~loc w r (fin_return, fin_raise, fin_kill) =
  (* Folds over a kernel tree *)
  let rec fold = function
  | Value.KernelVal (v, w) -> fin_return (v, w)

  | Value.(KernelException (Exception (exc, v), w)) ->
     let f_exc = lookup_finally_exception ~loc fin_raise exc in
     f_exc (v, w)

  | Value.(KernelSignal (Signal (sgn, v))) ->
     let f_sgn = lookup_signal ~loc fin_kill sgn in
     f_sgn v

  | Value.KernelOperation (op, v_op, f_return, f_exc) ->
     let f_return = fun v -> fold (f_return v)
     and f_exc = Name.Map.map (fun f v -> fold (f v)) f_exc in
     Value.UserOperation (op, v_op, f_return, f_exc)
  in
  fold (r w)

let top_eval_user {env_vars; env_container=coops} ({Location.loc; _} as c) =
  let rec using = function
    | Value.UserVal v -> v

    | Value.(UserException (Exception (exc, v))) ->
       error ~loc (UnhandledException exc)

    | Value.UserOperation (op, v, f_return, f_exc) ->
       let coop = lookup_operation ~loc coops op in
       begin
         try
           using (f_return (coop v))
         with
         | Value.(CoopException (Exception (exc, v))) ->
            let f = lookup_finally_exception ~loc f_exc exc in
            using (f v)
       end
  in
  let r = eval_user env_vars c in
  using r


let rec eval_toplevel ~quiet ({env_vars; env_container} as env) {Location.it=d'; loc} =
  match d' with

  | Syntax.TopLoad cs ->
     eval_topfile ~quiet {env_vars; env_container} cs

  | Syntax.TopLet (p, xts, c) ->
     let v = top_eval_user env c in
     let env_vars, vs = top_extend_pattern ~loc p v env_vars in
     if not quiet then
       List.iter2
         (fun (x, ty) v ->
           Format.printf "@[<hv 2>val %t :@ @[<hov>%t@]@ @[<hov 2>= %t@]@]@."
                         (Name.print x)
                         (Syntax.print_expr_ty ty)
                         (Value.print v))
         xts vs ;
     { env with env_vars }

  | Syntax.TopLetRec (pcs, fts) ->
     let env_vars = extend_rec ~loc pcs env_vars in
     if not quiet then
       List.iter
         (fun (f, t) ->
           Format.printf "@[<hov>val %t@ :@ %t@ =@ <fun>@]@."
                         (Name.print f)
                         (Syntax.print_expr_ty t))
         fts ;
     { env with env_vars }

  | Syntax.TopUser (c, ty) ->
     let v = top_eval_user env c in
     if not quiet then
       Format.printf "@[<hov>- :@ %t@ =@ %t@]@."
                     (Syntax.print_expr_ty ty)
                     (Value.print v) ;
     env

  | Syntax.TopContainer (cs, ops) ->
     let rec fold cnt = function
       | [] ->
          let env = set_container cnt env in
          if not quiet then
            Format.printf "@[<hov>container@ %t@]@." (Syntax.print_container_ty ops) ;
          env
       | c :: cs ->
          let v = top_eval_user env c in
          let c_cnt = as_container ~loc v in
          let cnts =
            Name.Map.merge
            (fun op f_opt g_opt ->
              match f_opt, g_opt with
              | Some f, None -> Some f
              | None, Some g -> Some g
              | None, None -> None
              | Some _, Some _ -> error ~loc (ContainerDoubleOperation op))
            cnt c_cnt
          in
          fold cnts cs
     in
     fold Name.Map.empty cs

  | Syntax.DefineAbstract t ->
     if not quiet then
       Format.printf "@[<hov>type %t@]@." (Name.print t) ;
     env

  | Syntax.DefineAlias (t, abbrev) ->
     if not quiet then
       Format.printf "@[<hov>type %t@ =@ %t@]@."
                     (Name.print t)
                     (Syntax.print_expr_ty abbrev) ;
     env

  | Syntax.DefineDatatype lst ->
     if not quiet then
       Format.printf "@[<v>type %t@]@." (Syntax.print_datatypes lst) ;
     env

  | Syntax.DeclareOperation (op, ty1, ty2) ->
     if not quiet then
       Format.printf "@[<hov>operation %t@ :@ %t@ %s@ %t@]@."
                     (Name.print op)
                     (Syntax.print_expr_ty ty1)
                     (Print.char_arrow ())
                     (Syntax.print_expr_ty ty2) ;
     env

  | Syntax.DeclareException (exc, t) ->
     if not quiet then
       Format.printf "@[<hov>exception %t@ of@ %t@]@."
                     (Name.print exc)
                     (Syntax.print_expr_ty t) ;
     env

  | Syntax.DeclareSignal (sgl, t) ->
     if not quiet then
       Format.printf "@[<hov>signal %t@ of@ %t@]@."
                     (Name.print sgl)
                     (Syntax.print_expr_ty t) ;
     env

  | Syntax.External (x, t, s) ->
     begin
       match External.lookup s with
       | None -> error ~loc (UnknownExternal s)
       | Some v ->
          let env_vars = extend_var v env_vars in
          if not quiet then
            Format.printf "@[<hov>external %t@ :@ %t = \"%s\"@]@."
                          (Name.print x)
                          (Syntax.print_expr_ty t)
                          s ;
          { env with env_vars }
     end

and eval_topfile ~quiet env lst =
  let rec fold env = function
    | [] -> env
    | top_cmd :: lst ->
       let env = eval_toplevel ~quiet env top_cmd in
       fold env lst
  in
  fold env lst
