open Base
open Lang
open Common
open ProblemDefs

val compute_preconds
  :  ctx:Env.env
  -> p:PsiDef.t
  -> term_state:Common.ProblemDefs.term_state
  -> (Term.term -> Term.term)
  -> Term.term
  -> Term.term option

val filter_elims
  :  ctx:Term.Context.t
  -> (Term.term * 'a) list
  -> Term.term
  -> (Term.term * 'a) list

val make
  :  ?force_replace_off:bool
  -> ctx:Env.env
  -> p:PsiDef.t
  -> term_state:Common.ProblemDefs.term_state
  -> lifting:Common.ProblemDefs.lifting
  -> Term.TermSet.t
  -> Common.ProblemDefs.equation list * Common.ProblemDefs.lifting

val revert_projs
  :  ctx:Env.env
  -> Term.VarSet.t
  -> (int, Term.variable list, Int.comparator_witness) Map.t
  -> (string * Term.variable list * Term.term) list
  -> (string * Term.variable list * Term.term) list

val free_vars_of_equations
  :  ctx:Env.env
  -> Common.ProblemDefs.equation list
  -> Term.VarSet.t

type partial_soln = (string * Term.variable list * Term.term) list

val pp_partial_soln
  :  ctx:Env.env
  -> Formatter.t
  -> (string * Term.variable list * Term.term) list
  -> unit

val solve
  :  Env.env
  -> p:PsiDef.t
  -> Common.ProblemDefs.equation list
  -> Syguslib.Sygus.solver_response
     * (partial_soln, Common.ProblemDefs.unrealizability_ctex list) Either.t

val update_assumptions
  :  ctx:Env.env
  -> p:PsiDef.t
  -> Common.ProblemDefs.refinement_loop_state
  -> partial_soln
  -> Term.TermSet.t
  -> Common.ProblemDefs.refinement_loop_state