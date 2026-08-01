(* Control-flow validation and label lookup for TP2 action and patch blocks. *)

open Tp

type flow =
  | Break
  | Goto of string

exception Action_flow of flow
exception Patch_flow of flow * string

module ActionBlockKey = struct
  type t = tp_action list
  let equal left right = left == right
  let hash = Hashtbl.hash
end

module PatchBlockKey = struct
  type t = tp_patch list
  let equal left right = left == right
  let hash = Hashtbl.hash
end

module ActionBlockCache = Hashtbl.Make(ActionBlockKey)
module PatchBlockCache = Hashtbl.Make(PatchBlockKey)
module StringSet = Set.Make(String)

let action_block_cache = ActionBlockCache.create 31
let patch_block_cache = PatchBlockCache.create 31

let build_action_targets actions =
  let targets = Hashtbl.create 5 in
  let rec collect = function
    | [] -> ()
    | TP_ActionLabel target :: tail ->
        if not (Hashtbl.mem targets target.control_name) then
          Hashtbl.add targets target.control_name tail ;
        collect tail
    | _ :: tail -> collect tail
  in
  collect actions ;
  ActionBlockCache.replace action_block_cache actions targets ;
  targets

let build_patch_targets patches =
  let targets = Hashtbl.create 5 in
  let rec collect = function
    | [] -> ()
    | TP_PatchLabel target :: tail ->
        if not (Hashtbl.mem targets target.control_name) then
          Hashtbl.add targets target.control_name tail ;
        collect tail
    | _ :: tail -> collect tail
  in
  collect patches ;
  PatchBlockCache.replace patch_block_cache patches targets ;
  targets

let action_targets actions =
  try ActionBlockCache.find action_block_cache actions
  with Not_found -> build_action_targets actions

let patch_targets patches =
  try PatchBlockCache.find patch_block_cache patches
  with Not_found -> build_patch_targets patches

let action_label_target actions name =
  try Some (Hashtbl.find (action_targets actions) name)
  with Not_found -> None

let patch_label_target patches name =
  try Some (Hashtbl.find (patch_targets patches) name)
  with Not_found -> None

let action_block_has_labels actions =
  Hashtbl.length (action_targets actions) <> 0

let patch_block_has_labels patches =
  Hashtbl.length (patch_targets patches) <> 0

let validation_error location format =
  Printf.ksprintf
    (fun message ->
      let filename =
        if location.control_filename = "" then "<input>"
        else location.control_filename
      in
      failwith
        (Printf.sprintf "%s:%d:%d: control statement error: %s"
           filename location.control_line location.control_column message))
    format

let validate_target_name statement target =
  if target.control_name = "" then
    validation_error target.control_location "%s requires a non-empty label name"
      statement

let collect_action_labels visible actions =
  let current = ref visible in
  List.iter
    (function
      | TP_ActionLabel target ->
          validate_target_name "an action label" target ;
          if StringSet.mem target.control_name !current then
            validation_error target.control_location
              "action label %S duplicates a label visible in this block"
              target.control_name ;
          current := StringSet.add target.control_name !current
      | _ -> ())
    actions ;
  ignore (build_action_targets actions) ;
  !current

let collect_patch_labels visible patches =
  let current = ref visible in
  List.iter
    (function
      | TP_PatchLabel target ->
          validate_target_name "a patch label" target ;
          if StringSet.mem target.control_name !current then
            validation_error target.control_location
              "patch label %S duplicates a label visible in this block"
              target.control_name ;
          current := StringSet.add target.control_name !current
      | _ -> ())
    patches ;
  ignore (build_patch_targets patches) ;
  !current

let rec validate_action_block visible loop_depth actions =
  let visible = collect_action_labels visible actions in
  List.iter (validate_action visible loop_depth) actions

and validate_action visible loop_depth = function
  | TP_ActionLabel _ -> ()
  | TP_ActionGoto target ->
      validate_target_name "GOTO" target ;
      if not (StringSet.mem target.control_name visible) then
        validation_error target.control_location
          "GOTO %S has no visible action label" target.control_name
  | TP_ActionBreak location ->
      if loop_depth = 0 then
        validation_error location "BREAK is not inside an action loop"
  | TP_ActionBashFor (_, body)
  | TP_ActionPHPEach (_, _, _, body)
  | TP_Action_For_Each (_, _, body)
  | TP_Outer_While (_, body) ->
      validate_action_block visible (loop_depth + 1) body
  | TP_Outer_For (initializers, _, increments, body) ->
      validate_patch_block StringSet.empty 0 initializers ;
      validate_patch_block StringSet.empty 0 increments ;
      validate_action_block visible (loop_depth + 1) body
  | TP_If (_, if_true, if_false) ->
      validate_action_block visible loop_depth if_true ;
      validate_action_block visible loop_depth if_false
  | TP_ActionTry (body, handlers) ->
      validate_action_block visible loop_depth body ;
      List.iter
        (fun (_, _, handler) ->
          validate_action_block visible loop_depth handler)
        handlers
  | TP_ActionMatch (_, handlers) ->
      List.iter
        (fun (_, _, handler) ->
          validate_action_block visible loop_depth handler)
        handlers
  | TP_WithTra (_, body)
  | TP_WithVarScope body
  | TP_ActionTime (_, body) ->
      validate_action_block visible loop_depth body
  | TP_Define_Action_Macro (_, _, body)
  | TP_Define_Action_Function (_, _, _, _, _, body)
  | TP_Define_Dimorphic_Function (_, _, _, _, _, body) ->
      validate_action_block StringSet.empty 0 body
  | TP_Define_Patch_Macro (_, _, body)
  | TP_Define_Patch_Function (_, _, _, _, _, body) ->
      validate_patch_block StringSet.empty 0 body
  | TP_CopyAllGamFiles (patches, _)
  | TP_CopyRandom (_, patches, _)
  | TP_Compile (_, _, patches, _)
  | TP_Outer_Inner_Buff (_, patches)
  | TP_Outer_Inner_Buff_Save (_, _, patches)
  | TP_Extend_Top (_, _, _, patches, _, _)
  | TP_Extend_Bottom (_, _, _, patches, _, _)
  | TP_Alter_TLK patches
  | TP_Alter_TLK_Range (_, _, patches)
  | TP_Alter_TLK_List (_, patches)
  | TP_Create (_, _, _, patches) ->
      validate_patch_block StringSet.empty 0 patches
  | TP_Copy args ->
      validate_patch_block StringSet.empty 0 args.copy_patch_list
  | TP_Add_Spell (_, _, _, _, patches, if_existing, on_disable) ->
      validate_patch_block StringSet.empty 0 patches ;
      (match if_existing with
       | Some body -> validate_patch_block StringSet.empty 0 body
       | None -> ()) ;
      (match on_disable with
       | Some body -> validate_patch_block StringSet.empty 0 body
       | None -> ())
  | _ -> ()

and validate_patch_block visible loop_depth patches =
  let visible = collect_patch_labels visible patches in
  List.iter (validate_patch visible loop_depth) patches

and validate_patch visible loop_depth = function
  | TP_PatchLabel _ -> ()
  | TP_PatchGoto target ->
      validate_target_name "GOTO" target ;
      if not (StringSet.mem target.control_name visible) then
        validation_error target.control_location
          "GOTO %S has no visible patch label" target.control_name
  | TP_PatchBreak location ->
      if loop_depth = 0 then
        validation_error location "BREAK is not inside a patch loop"
  | TP_PatchBashFor (_, body)
  | TP_PatchPHPEach (_, _, _, body)
  | TP_PatchForEach (_, _, body)
  | TP_PatchWhile (_, body) ->
      validate_patch_block visible (loop_depth + 1) body
  | TP_PatchFor (initializers, _, increments, body) ->
      validate_patch_block visible 0 initializers ;
      validate_patch_block visible 0 increments ;
      validate_patch_block visible (loop_depth + 1) body
  | TP_PatchIf (_, if_true, if_false) ->
      validate_patch_block visible loop_depth if_true ;
      validate_patch_block visible loop_depth if_false
  | TP_PatchTry (body, handlers) ->
      validate_patch_block visible loop_depth body ;
      List.iter
        (fun (_, _, handler) ->
          validate_patch_block visible loop_depth handler)
        handlers
  | TP_PatchMatch (_, handlers) ->
      List.iter
        (fun (_, _, handler) ->
          validate_patch_block visible loop_depth handler)
        handlers
  | TP_PatchReplaceBCSBlock (_, _, Some body, _, _)
  | TP_PatchReplaceBCSBlockRE (_, _, Some body)
  | TP_PatchWithTra (_, body)
  | TP_PatchWithVarScope body
  | TP_PatchTime (_, body) ->
      validate_patch_block visible loop_depth body
  | TP_PatchStringEvaluate (_, _, body, _)
  | TP_PatchInnerBuff (_, body)
  | TP_PatchInnerBuffFile (_, body)
  | TP_PatchInnerBuffSave (_, _, body)
  | TP_PatchSavFile (_, _, _, body)
  | TP_DecompileAndPatch body ->
      validate_patch_block StringSet.empty 0 body
  | TP_PatchInnerAction actions ->
      validate_action_block StringSet.empty 0 actions
  | _ -> ()

let validate_action_root actions =
  validate_action_block StringSet.empty 0 actions

let validate_patch_root patches =
  validate_patch_block StringSet.empty 0 patches

let validate_tp_file tp =
  List.iter
    (function
      | Always actions
      | Define_Action_Macro (_, _, actions) -> validate_action_root actions
      | Define_Patch_Macro (_, _, patches) -> validate_patch_root patches
      | _ -> ())
    tp.flags ;
  List.iter (fun component -> validate_action_root component.mod_parts)
    tp.module_list
