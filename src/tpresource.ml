(* Structured, validated editing for ITM, SPL and EFF resources. *)

open BatteriesInit
open Util
open Tp

exception Error of string

let error fmt =
  Printf.ksprintf (fun message -> raise (Error ("PATCH_RESOURCE: " ^ message))) fmt

type field_kind =
  | U8 | I8 | U16 | I16 | I32
  | FixedString of int
  | Resref

type field = {
  field_name : string;
  field_offset : int;
  field_kind : field_kind;
  field_writable : bool;
}

type record_desc = {
  record_name : string;
  record_size : int;
  record_fields : field list;
}

type node_kind = Root | Ability | Effect

type node = {
  node_id : int;
  node_kind : node_kind;
  node_desc : record_desc;
  mutable node_bytes : string;
  mutable node_deleted : bool;
  mutable node_effects : node list;
}

type format =
  | ItmV1 | ItmV11 | ItmV20
  | SplV1 | SplV20
  | EffV20

type editor = {
  editor_kind : tp_resource_kind;
  editor_format : format;
  editor_original : string;
  editor_root : node;
  mutable editor_abilities : node list;
  mutable editor_globals : node list;
  editor_gap : string;
  editor_tail : string;
  editor_handles : (string, node) Hashtbl.t;
  mutable editor_next_id : int;
  mutable editor_dirty : bool;
}

type value = Numeric of Int32.t | Text of string

let ro name offset kind =
  { field_name = name; field_offset = offset; field_kind = kind;
    field_writable = false }

let rw name offset kind =
  { field_name = name; field_offset = offset; field_kind = kind;
    field_writable = true }

let embedded_effect_fields = [
  rw "opcode" 0x00 U16;
  rw "target" 0x02 U8;
  rw "power" 0x03 U8;
  rw "parameter1" 0x04 I32;
  rw "parameter2" 0x08 I32;
  rw "timing" 0x0c U8;
  rw "resist_dispel" 0x0d U8;
  rw "duration" 0x0e I32;
  rw "probability1" 0x12 U8;
  rw "probability2" 0x13 U8;
  rw "resource" 0x14 Resref;
  rw "dicenumber" 0x1c I32;
  rw "dicesize" 0x20 I32;
  rw "savingthrow" 0x24 I32;
  rw "savebonus" 0x28 I32;
  rw "special" 0x2c I32;
]

let embedded_effect_desc = {
  record_name = "embedded effect";
  record_size = 0x30;
  record_fields = embedded_effect_fields;
}

let itm_ability_base_fields = [
  rw "header_type" 0x00 U8;
  rw "id_requirement" 0x01 U8;
  rw "location" 0x02 U8;
  rw "alternative_dice_sides" 0x03 U8;
  rw "icon" 0x04 Resref;
  rw "target" 0x0c U8;
  rw "target_count" 0x0d U8;
  rw "range" 0x0e U16;
  rw "launcher" 0x10 U8;
  rw "alternative_dice_thrown" 0x11 U8;
  rw "speed" 0x12 U8;
  rw "alternative_damage_bonus" 0x13 U8;
  rw "thac0_bonus" 0x14 I16;
  rw "dicesize" 0x16 U8;
  rw "primary_type" 0x17 U8;
  rw "dicenumber" 0x18 U8;
  rw "secondary_type" 0x19 U8;
  rw "damage_bonus" 0x1a I16;
  rw "damage_type" 0x1c U16;
  ro "effects_count" 0x1e U16;
  ro "effects_index" 0x20 U16;
  rw "charges" 0x22 U16;
  rw "drained" 0x24 U16;
]

let itm_v1_ability_fields = itm_ability_base_fields @ [
  rw "flags" 0x26 I32;
  rw "projectile" 0x2a U16;
  rw "animation_overhand" 0x2c U16;
  rw "animation_backhand" 0x2e U16;
  rw "animation_thrust" 0x30 U16;
  rw "arrow" 0x32 U16;
  rw "bolt" 0x34 U16;
  rw "bullet" 0x36 U16;
]

let itm_v2_ability_fields = itm_ability_base_fields @ [
  rw "flags" 0x26 U16;
  rw "attack_type_flags" 0x28 U16;
  rw "projectile" 0x2a U16;
  rw "animation_overhand" 0x2c U16;
  rw "animation_backhand" 0x2e U16;
  rw "animation_thrust" 0x30 U16;
  rw "arrow" 0x32 U16;
  rw "bolt" 0x34 U16;
  rw "bullet" 0x36 U16;
]

let itm_v1_ability_desc = {
  record_name = "ITM V1/V1.1 ability";
  record_size = 0x38;
  record_fields = itm_v1_ability_fields;
}

let itm_v2_ability_desc = {
  record_name = "ITM V2.0 ability";
  record_size = 0x38;
  record_fields = itm_v2_ability_fields;
}

let spl_ability_fields = [
  rw "header_type" 0x00 U8;
  rw "flags" 0x01 U8;
  rw "location" 0x02 U16;
  rw "icon" 0x04 Resref;
  rw "target" 0x0c U8;
  rw "target_count" 0x0d U8;
  rw "range" 0x0e U16;
  rw "min_level" 0x10 U16;
  rw "speed" 0x12 U16;
  rw "times_per_day" 0x14 U16;
  ro "effects_count" 0x1e U16;
  ro "effects_index" 0x20 U16;
  rw "projectile" 0x26 U16;
]

let spl_ability_desc = {
  record_name = "SPL ability";
  record_size = 0x28;
  record_fields = spl_ability_fields;
}

let structural_fields = [
  ro "abilities_offset" 0x64 I32;
  ro "abilities_count" 0x68 U16;
  ro "effects_offset" 0x6a I32;
  ro "global_effects_index" 0x6e U16;
  ro "global_effects_count" 0x70 U16;
]

let itm_common_fields = [
  ro "signature" 0x00 (FixedString 4);
  ro "version" 0x04 (FixedString 4);
  rw "unidentified_name" 0x08 I32;
  rw "identified_name" 0x0c I32;
  rw "flags" 0x18 I32;
  rw "item_type" 0x1c U16;
  rw "usability_flags" 0x1e I32;
  rw "item_animation" 0x22 (FixedString 2);
  rw "min_level" 0x24 U16;
  rw "price" 0x34 I32;
  rw "stack_amount" 0x38 U16;
  rw "inventory_icon" 0x3a Resref;
  rw "lore_to_id" 0x42 U16;
  rw "ground_icon" 0x44 Resref;
  rw "weight" 0x4c I32;
  rw "unidentified_description" 0x50 I32;
  rw "identified_description" 0x54 I32;
  rw "enchantment" 0x60 I32;
] @ structural_fields

let itm_requirement_fields = [
  rw "min_strength" 0x26 U16;
  rw "min_strength_bonus" 0x28 U8;
  rw "kit_usability1" 0x29 U8;
  rw "min_intelligence" 0x2a U8;
  rw "kit_usability2" 0x2b U8;
  rw "min_dexterity" 0x2c U8;
  rw "kit_usability3" 0x2d U8;
  rw "min_wisdom" 0x2e U8;
  rw "kit_usability4" 0x2f U8;
  rw "min_constitution" 0x30 U8;
  rw "weapon_proficiency" 0x31 U8;
  rw "min_charisma" 0x32 U16;
]

let spl_common_fields = [
  ro "signature" 0x00 (FixedString 4);
  ro "version" 0x04 (FixedString 4);
  rw "name" 0x08 I32;
  rw "completion_sound" 0x10 Resref;
  rw "flags" 0x18 I32;
  rw "spell_type" 0x1c U16;
  rw "exclusion_flags" 0x1e I32;
  rw "casting_graphics" 0x22 U16;
  rw "primary_type" 0x25 U8;
  rw "secondary_type" 0x27 U8;
  rw "spell_level" 0x34 I32;
  rw "spellbook_icon" 0x3a Resref;
  rw "description" 0x50 I32;
] @ structural_fields

let eff_v2_fields = [
  ro "signature" 0x00 (FixedString 4);
  ro "version" 0x04 (FixedString 4);
  ro "body_signature" 0x08 (FixedString 4);
  ro "body_version" 0x0c (FixedString 4);
  rw "opcode" 0x10 I32;
  rw "target" 0x14 I32;
  rw "power" 0x18 I32;
  rw "parameter1" 0x1c I32;
  rw "parameter2" 0x20 I32;
  rw "timing" 0x24 U16;
  rw "duration" 0x28 I32;
  rw "probability1" 0x2c U16;
  rw "probability2" 0x2e U16;
  rw "resource" 0x30 Resref;
  rw "dicenumber" 0x38 I32;
  rw "dicesize" 0x3c I32;
  rw "savingthrow" 0x40 I32;
  rw "savebonus" 0x44 I32;
  rw "special" 0x48 I32;
  rw "primary_type" 0x4c I32;
  rw "resist_dispel" 0x5c I32;
  rw "parameter3" 0x60 I32;
  rw "parameter4" 0x64 I32;
  rw "parameter5" 0x68 I32;
  rw "time_applied" 0x6c I32;
  rw "resource2" 0x70 Resref;
  rw "resource3" 0x78 Resref;
  rw "caster_x" 0x80 I32;
  rw "caster_y" 0x84 I32;
  rw "target_x" 0x88 I32;
  rw "target_y" 0x8c I32;
  rw "parent_resource_type" 0x90 I32;
  rw "parent_resource" 0x94 Resref;
  rw "parent_resource_flags" 0x9c I32;
  rw "projectile" 0xa0 I32;
  rw "variable_name" 0xa8 (FixedString 32);
  rw "caster_level" 0xc8 I32;
  rw "secondary_type" 0xd0 I32;
]

let field_width = function
  | U8 | I8 -> 1
  | U16 | I16 -> 2
  | I32 -> 4
  | FixedString size -> size
  | Resref -> 8

let validate_desc desc =
  let names = Hashtbl.create 31 in
  List.iter (fun field ->
    let name = String.lowercase field.field_name in
    if Hashtbl.mem names name then
      error "internal schema %s contains duplicate field %s"
        desc.record_name field.field_name;
    Hashtbl.add names name ();
    let finish = field.field_offset + field_width field.field_kind in
    if field.field_offset < 0 || finish > desc.record_size then
      error "internal schema %s field %s is out of bounds"
        desc.record_name field.field_name) desc.record_fields

let make_desc name size fields =
  let desc = { record_name = name; record_size = size; record_fields = fields } in
  validate_desc desc;
  desc

let itm_root_desc format =
  match format with
  | ItmV1 -> make_desc "ITM V1 root" 0x72
      ([rw "used_up_item" 0x10 Resref; rw "description_icon" 0x58 Resref] @
       itm_requirement_fields @ itm_common_fields)
  | ItmV11 -> make_desc "ITM V1.1 root" 0x9a
      ([rw "drop_sound" 0x10 Resref; rw "pickup_sound" 0x58 Resref;
        rw "dialog" 0x72 Resref; rw "conversable_label" 0x7a I32;
        rw "paperdoll_colour" 0x7e U16] @ itm_common_fields)
  | ItmV20 -> make_desc "ITM V2.0 root" 0x82
      ([rw "replacement_item" 0x10 Resref; rw "description_icon" 0x58 Resref] @
       itm_requirement_fields @ itm_common_fields)
  | _ -> assert false

let spl_root_desc format =
  let fields = match format with
  | SplV20 ->
      rw "duration_modifier_level" 0x72 U8 ::
      rw "duration_modifier_rounds" 0x73 U8 :: spl_common_fields
  | SplV1 -> spl_common_fields
  | _ -> assert false in
  make_desc (if format = SplV20 then "SPL V2.0 root" else "SPL V1 root")
    (if format = SplV20 then 0x82 else 0x72) fields

let eff_root_desc = make_desc "EFF V2.0 root" 0x110 eff_v2_fields

let () =
  validate_desc embedded_effect_desc;
  validate_desc itm_v1_ability_desc;
  validate_desc itm_v2_ability_desc;
  validate_desc spl_ability_desc;
  ignore (itm_root_desc ItmV1);
  ignore (itm_root_desc ItmV11);
  ignore (itm_root_desc ItmV20);
  ignore (spl_root_desc SplV1);
  ignore (spl_root_desc SplV20);
  validate_desc eff_root_desc

let u32_at bytes offset =
  let value = int32_of_str_off bytes offset in
  let wide = Int64.logand (Int64.of_int32 value) 0xffffffffL in
  if wide > Int64.of_int max_int then
    error "offset 0x%Lx cannot be represented on this host" wide;
  Int64.to_int wide

let checked_end label offset count stride length =
  if offset < 0 || count < 0 || stride < 0 then
    error "%s has a negative layout value" label;
  let finish = Int64.add (Int64.of_int offset)
      (Int64.mul (Int64.of_int count) (Int64.of_int stride)) in
  if finish > Int64.of_int length then
    error "%s extends past the %d-byte buffer" label length;
  Int64.to_int finish

let copy_slice bytes offset length = String.sub bytes offset length

let new_node id kind desc bytes = {
  node_id = id; node_kind = kind; node_desc = desc;
  node_bytes = bytes; node_deleted = false; node_effects = [];
}

let format_of_signature requested bytes =
  if String.length bytes < 8 then error "buffer is shorter than a signature";
  let signature = String.sub bytes 0 8 in
  match requested, signature with
  | TP_Resource_ITM, "ITM V1  " -> ItmV1
  | TP_Resource_ITM, "ITM V1.1" -> ItmV11
  | TP_Resource_ITM, "ITM V2.0" -> ItmV20
  | TP_Resource_SPL, "SPL V1  " -> SplV1
  | TP_Resource_SPL, "SPL V2.0" -> SplV20
  | TP_Resource_EFF, "EFF V2.0" -> EffV20
  | TP_Resource_ITM, _ -> error "expected ITM V1, V1.1 or V2.0; found %S" signature
  | TP_Resource_SPL, _ -> error "expected SPL V1 or V2.0; found %S" signature
  | TP_Resource_EFF, _ -> error "expected EFF V2.0; found %S" signature

let parse requested bytes =
  let format = format_of_signature requested bytes in
  let length = String.length bytes in
  match format with
  | EffV20 ->
      if length < eff_root_desc.record_size then
        error "EFF V2.0 buffer is %d bytes; minimum is %d"
          length eff_root_desc.record_size;
      let root = new_node 0 Root eff_root_desc
          (copy_slice bytes 0 eff_root_desc.record_size) in
      { editor_kind = requested; editor_format = format;
        editor_original = String.copy bytes; editor_root = root;
        editor_abilities = []; editor_globals = [];
        editor_gap = "";
        editor_tail = copy_slice bytes eff_root_desc.record_size
            (length - eff_root_desc.record_size);
        editor_handles = Hashtbl.create 17; editor_next_id = 1;
        editor_dirty = false }
  | ItmV1 | ItmV11 | ItmV20 | SplV1 | SplV20 ->
      let root_desc, ability_desc = match format with
      | ItmV1 | ItmV11 -> itm_root_desc format, itm_v1_ability_desc
      | ItmV20 -> itm_root_desc format, itm_v2_ability_desc
      | SplV1 | SplV20 -> spl_root_desc format, spl_ability_desc
      | _ -> assert false in
      if length < root_desc.record_size then
        error "%s buffer is %d bytes; minimum is %d"
          root_desc.record_name length root_desc.record_size;
      let ability_offset = u32_at bytes 0x64 in
      let ability_count = short_of_str_off bytes 0x68 in
      let effects_offset = u32_at bytes 0x6a in
      let global_index = short_of_str_off bytes 0x6e in
      let global_count = short_of_str_off bytes 0x70 in
      if ability_offset < root_desc.record_size then
        error "ability offset 0x%x overlaps the fixed header" ability_offset;
      let ability_end = checked_end "ability table" ability_offset ability_count
          ability_desc.record_size length in
      if effects_offset < ability_end then
        error "effect table offset 0x%x overlaps the ability table" effects_offset;
      if global_index <> 0 then
        error "global effect index is %d; records before it have ambiguous ownership"
          global_index;
      let next_id = ref 1 in
      let abilities = ref [] in
      for index = 0 to ability_count - 1 do
        let offset = ability_offset + index * ability_desc.record_size in
        let node = new_node !next_id Ability ability_desc
            (copy_slice bytes offset ability_desc.record_size) in
        incr next_id;
        abilities := node :: !abilities
      done;
      let abilities = List.rev !abilities in
      let expected_index = ref global_count in
      List.iteri (fun index ability ->
        let count = short_of_str_off ability.node_bytes 0x1e in
        let first = short_of_str_off ability.node_bytes 0x20 in
        if first <> !expected_index then
          error "ability %d starts at effect %d; expected %d (gap, overlap, or reordered ownership)"
            index first !expected_index;
        expected_index := !expected_index + count) abilities;
      let effect_count = !expected_index in
      let effects_end = checked_end "effect table" effects_offset effect_count
          embedded_effect_desc.record_size length in
      let effects = Array.init effect_count (fun index ->
        let offset = effects_offset + index * embedded_effect_desc.record_size in
        let node = new_node !next_id Effect embedded_effect_desc
            (copy_slice bytes offset embedded_effect_desc.record_size) in
        incr next_id; node) in
      let globals = ref [] in
      for index = 0 to global_count - 1 do globals := effects.(index) :: !globals done;
      let cursor = ref global_count in
      List.iter (fun ability ->
        let count = short_of_str_off ability.node_bytes 0x1e in
        let owned = ref [] in
        for index = 0 to count - 1 do
          owned := effects.(!cursor + index) :: !owned
        done;
        ability.node_effects <- List.rev !owned;
        cursor := !cursor + count) abilities;
      let root = new_node 0 Root root_desc (copy_slice bytes 0 ability_offset) in
      { editor_kind = requested; editor_format = format;
        editor_original = String.copy bytes; editor_root = root;
        editor_abilities = abilities; editor_globals = List.rev !globals;
        editor_gap = copy_slice bytes ability_end (effects_offset - ability_end);
        editor_tail = copy_slice bytes effects_end (length - effects_end);
        editor_handles = Hashtbl.create 17; editor_next_id = !next_id;
        editor_dirty = false }

let current : editor option ref = ref None

let is_active () = !current <> None

let active () = match !current with
  | Some editor -> editor
  | None -> error "structured command used outside PATCH_RESOURCE"

let activate editor =
  if is_active () then error "nested PATCH_RESOURCE blocks are not allowed";
  Hashtbl.replace editor.editor_handles "resource" editor.editor_root;
  current := Some editor

let deactivate () = current := None

let original_buffer () = (active ()).editor_original

let lowercase = String.lowercase

let resolve_handle editor name =
  let key = lowercase name in
  let node = try Hashtbl.find editor.editor_handles key
    with Not_found -> error "unknown handle %S" name in
  if node.node_deleted then error "handle %S refers to a deleted record" name;
  node

let with_binding editor name node body =
  let key = lowercase name in
  if key = "resource" then error "RESOURCE is reserved for the root handle";
  let previous = try Some (Hashtbl.find editor.editor_handles key)
    with Not_found -> None in
  Hashtbl.replace editor.editor_handles key node;
  try
    let result = body () in
    (match previous with Some old -> Hashtbl.replace editor.editor_handles key old
     | None -> Hashtbl.remove editor.editor_handles key);
    result
  with exn ->
    (match previous with Some old -> Hashtbl.replace editor.editor_handles key old
     | None -> Hashtbl.remove editor.editor_handles key);
    raise exn

let find_field node name =
  let key = lowercase name in
  try List.find (fun field -> lowercase field.field_name = key)
      node.node_desc.record_fields
  with Not_found ->
    error "%s has no field %S" node.node_desc.record_name name

let trim_zeroes value =
  try String.sub value 0 (String.index value '\000') with Not_found -> value

let read node field_name =
  let field = find_field node field_name in
  let offset = field.field_offset in
  match field.field_kind with
  | U8 -> Numeric (Int32.of_int (byte_of_str_off node.node_bytes offset))
  | I8 -> Numeric (Int32.of_int (signed_byte_of
      (byte_of_str_off node.node_bytes offset)))
  | U16 -> Numeric (Int32.of_int (short_of_str_off node.node_bytes offset))
  | I16 -> Numeric (Int32.of_int (signed_short_of
      (short_of_str_off node.node_bytes offset)))
  | I32 -> Numeric (int32_of_str_off node.node_bytes offset)
  | FixedString size -> Text (trim_zeroes (String.sub node.node_bytes offset size))
  | Resref -> Text (trim_zeroes (String.sub node.node_bytes offset 8))

let check_range field value low high =
  let wide = Int64.of_int32 value in
  if wide < Int64.of_int low || wide > Int64.of_int high then
    error "field %s requires a value from %d through %d; received %ld"
      field.field_name low high value

let write_numeric node field_name value =
  let field = find_field node field_name in
  if not field.field_writable then error "field %s is read-only" field.field_name;
  let offset = field.field_offset in
  (match field.field_kind with
  | U8 -> check_range field value 0 255;
      write_byte node.node_bytes offset (Int32.to_int value)
  | I8 -> check_range field value (-128) 127;
      write_byte node.node_bytes offset (Int32.to_int value)
  | U16 -> check_range field value 0 65535;
      write_short node.node_bytes offset (Int32.to_int value)
  | I16 -> check_range field value (-32768) 32767;
      write_short node.node_bytes offset (Int32.to_int value)
  | I32 -> write_int32 node.node_bytes offset value
  | FixedString _ | Resref ->
      error "field %s is textual; use RESOURCE_SPRINT" field.field_name);
  (active ()).editor_dirty <- true

let write_text node field_name value =
  let field = find_field node field_name in
  if not field.field_writable then error "field %s is read-only" field.field_name;
  let size = match field.field_kind with
  | FixedString size -> size | Resref -> 8
  | _ -> error "field %s is numeric; use RESOURCE_SET" field.field_name in
  if String.length value > size then
    error "field %s accepts at most %d bytes; received %d"
      field.field_name size (String.length value);
  let padded = String.make size '\000' in
  String.blit value 0 padded 0 (String.length value);
  String.blit padded 0 node.node_bytes field.field_offset size;
  (active ()).editor_dirty <- true

type collection_ref =
  | AbilityCollection
  | GlobalCollection
  | EffectCollection of node

let collection editor = function
  | TP_Resource_Abilities ->
      (match editor.editor_format with
       | EffV20 -> error "EFF resources have no abilities"
       | _ -> AbilityCollection)
  | TP_Resource_GlobalEffects ->
      (match editor.editor_format with
       | EffV20 -> error "EFF resources have no global effects"
       | _ -> GlobalCollection)
  | TP_Resource_EffectsOf handle ->
      let owner = resolve_handle editor handle in
      if owner.node_kind <> Ability then
        error "EFFECTS OF requires an ability handle";
      EffectCollection owner

let live list = List.filter (fun node -> not node.node_deleted) list

let collection_nodes editor = function
  | AbilityCollection -> live editor.editor_abilities
  | GlobalCollection -> live editor.editor_globals
  | EffectCollection owner -> live owner.node_effects

let set_collection editor target nodes = match target with
  | AbilityCollection -> editor.editor_abilities <- nodes
  | GlobalCollection -> editor.editor_globals <- nodes
  | EffectCollection owner -> owner.node_effects <- nodes

let make_zero editor target =
  let kind, desc = match target with
  | AbilityCollection -> Ability,
      (match editor.editor_format with
       | ItmV1 | ItmV11 -> itm_v1_ability_desc
       | ItmV20 -> itm_v2_ability_desc
       | SplV1 | SplV20 -> spl_ability_desc
       | EffV20 -> assert false)
  | GlobalCollection | EffectCollection _ -> Effect, embedded_effect_desc in
  let node = new_node editor.editor_next_id kind desc
      (String.make desc.record_size '\000') in
  editor.editor_next_id <- editor.editor_next_id + 1;
  node

let refresh_metadata editor = match editor.editor_format with
  | EffV20 -> ()
  | ItmV1 | ItmV11 | ItmV20 | SplV1 | SplV20 ->
      let abilities = live editor.editor_abilities in
      let globals = live editor.editor_globals in
      let ability_size = match abilities with
        | head :: _ -> head.node_desc.record_size
        | [] -> (match editor.editor_format with
          | ItmV1 | ItmV11 -> itm_v1_ability_desc.record_size
          | ItmV20 -> itm_v2_ability_desc.record_size
          | SplV1 | SplV20 -> spl_ability_desc.record_size
          | _ -> assert false) in
      let effects_offset = String.length editor.editor_root.node_bytes +
          List.length abilities * ability_size + String.length editor.editor_gap in
      write_short editor.editor_root.node_bytes 0x68 (List.length abilities);
      write_int editor.editor_root.node_bytes 0x6a effects_offset;
      write_short editor.editor_root.node_bytes 0x6e 0;
      write_short editor.editor_root.node_bytes 0x70 (List.length globals);
      let index = ref (List.length globals) in
      List.iter (fun ability ->
        let effects = live ability.node_effects in
        write_short ability.node_bytes 0x1e (List.length effects);
        write_short ability.node_bytes 0x20 !index;
        index := !index + List.length effects) abilities

let mark_changed editor = editor.editor_dirty <- true; refresh_metadata editor

let insert_relative nodes anchor before inserted =
  let rec walk acc = function
    | [] -> error "anchor does not belong to the selected collection"
    | head :: tail when head == anchor ->
        if before then List.rev_append acc (inserted :: head :: tail)
        else List.rev_append acc (head :: inserted :: tail)
    | head :: tail -> walk (head :: acc) tail in
  walk [] nodes

let add editor target position node =
  let nodes = collection_nodes editor target in
  let updated = match position with
  | None -> nodes @ [node]
  | Some (TP_Resource_Before handle) ->
      insert_relative nodes (resolve_handle editor handle) true node
  | Some (TP_Resource_After handle) ->
      insert_relative nodes (resolve_handle editor handle) false node in
  set_collection editor target updated;
  mark_changed editor

let clone_node editor source target = match source.node_kind, target with
  | Ability, AbilityCollection ->
      let clone = make_zero editor target in
      clone.node_bytes <- String.copy source.node_bytes;
      clone.node_effects <- List.map (fun effect ->
        let copy = make_zero editor (EffectCollection clone) in
        copy.node_bytes <- String.copy effect.node_bytes; copy)
        (live source.node_effects);
      clone
  | Effect, (GlobalCollection | EffectCollection _) ->
      let clone = make_zero editor target in
      clone.node_bytes <- String.copy source.node_bytes; clone
  | Root, _ -> error "the root record cannot be cloned"
  | Ability, _ -> error "an ability can only be cloned into ABILITIES"
  | Effect, AbilityCollection -> error "an effect cannot be cloned into ABILITIES"

let delete editor node =
  if node.node_kind = Root then error "the root record cannot be deleted";
  node.node_deleted <- true;
  if node.node_kind = Ability then
    List.iter (fun effect -> effect.node_deleted <- true) node.node_effects;
  mark_changed editor

let serialize editor =
  if not editor.editor_dirty then String.copy editor.editor_original else begin
    refresh_metadata editor;
    let output = Buffer.create (String.length editor.editor_original) in
    Buffer.add_string output editor.editor_root.node_bytes;
    List.iter (fun ability -> Buffer.add_string output ability.node_bytes)
      (live editor.editor_abilities);
    Buffer.add_string output editor.editor_gap;
    List.iter (fun effect -> Buffer.add_string output effect.node_bytes)
      (live editor.editor_globals);
    List.iter (fun ability ->
      List.iter (fun effect -> Buffer.add_string output effect.node_bytes)
        (live ability.node_effects)) (live editor.editor_abilities);
    Buffer.add_string output editor.editor_tail;
    let result = Buffer.contents output in
    ignore (parse editor.editor_kind result);
    result
  end

let get handle field =
  let editor = active () in read (resolve_handle editor handle) field

let set handle field value =
  let editor = active () in write_numeric (resolve_handle editor handle) field value

let sprint handle field value =
  let editor = active () in write_text (resolve_handle editor handle) field value

let for_each collection_spec handle body =
  let editor = active () in
  let snapshot = collection_nodes editor (collection editor collection_spec) in
  List.iter (fun node ->
    if not node.node_deleted then with_binding editor handle node body) snapshot

let append collection_spec handle body =
  let editor = active () in
  let target = collection editor collection_spec in
  let node = make_zero editor target in
  add editor target None node;
  with_binding editor handle node body

let insert collection_spec position handle body =
  let editor = active () in
  let target = collection editor collection_spec in
  let node = make_zero editor target in
  add editor target (Some position) node;
  with_binding editor handle node body

let clone source_handle collection_spec position handle body =
  let editor = active () in
  let source = resolve_handle editor source_handle in
  let target = collection editor collection_spec in
  let node = clone_node editor source target in
  add editor target position node;
  with_binding editor handle node body

let delete_handle handle =
  let editor = active () in delete editor (resolve_handle editor handle)
