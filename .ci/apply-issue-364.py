#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    occurrences = text.count(old)
    if occurrences != 1:
        raise SystemExit(
            f"{label}: expected exactly one source match, found {occurrences}"
        )
    return text.replace(old, new, 1)


tpaction_path = Path("src/tpaction.ml")
tpaction = tpaction_path.read_text(encoding="utf-8")

tpaction = replace_once(
    tpaction,
    '''  let kitlist_ex_p buff =
    (try Str.search_forward (Str.regexp "[\\r\\n][0-9]+[ \\t]+\\*[ \\t]+\\*")
                            buff 0 ; true
     with Not_found -> false) in

  let next_kitlist_ex_line buff =
    let _ = Str.search_forward
              (Str.regexp "[\\r\\n][0-9]+[ \\t]+\\*[ \\t]+\\*.+$")
              buff 0 in
    Str.string_after (Str.matched_string buff) 1 in

  let get_next_kit_number file =
    let resref, ext = split_resref file in
    let buff, path = Load.load_resource "getting 2DA lines" game true
                                        resref ext in
    if not (kitlist_ex_p buff) then (get_next_line_number file), false else
      (try
         let line = next_kitlist_ex_line buff in
         let number = int_of_string (List.hd (split_apart line)) in
         number, true
       with e ->
         log_and_print "ERROR: cannot find line numbers in %s\\n" file ;
         raise e) in
''',
    '''  let next_kitlist_ex_line buff =
    let filler_line = Str.regexp "^[0-9]+[ \\t]+\\*[ \\t]+\\*" in
    try
      Some (List.find
              (fun line -> Str.string_match filler_line line 0)
              (Str.split many_newline_or_cr_regexp buff))
    with Not_found -> None in

  let get_next_kit_number file =
    let resref, ext = split_resref file in
    let buff, path = Load.load_resource "getting 2DA lines" game true
                                        resref ext in
    match next_kitlist_ex_line buff with
    | None -> (get_next_line_number file), None
    | Some line ->
        (try
           let number = int_of_string (List.hd (split_apart line)) in
           number, Some line
         with e ->
           log_and_print "ERROR: cannot find line numbers in %s\\n" file ;
           raise e) in
''',
    "filler-row discovery",
)

tpaction = replace_once(
    tpaction,
    '''  let kitlist_action number kit_name lower_index mixed_index help_index
                     abil_file prof_number unused_class exp =
    if not exp then begin
        let append_to_kitlist = Printf.sprintf
                                  "%d  %s %d %d %d %s %d %s"
                                  number kit_name lower_index mixed_index
                                  help_index abil_file prof_number
                                  unused_class in

        TP_Append("KITLIST.2DA",append_to_kitlist,[],true,false,0) end
    else begin
        let row = string_of_int (number + 3) in
        let patch =
          TP_PatchIf
            (PE_GT (get_pe_int "%SOURCE_SIZE%", get_pe_int "0"),
             (* no measureble performance impact on my machine with
              * conventional HDD - Wisp *)
             [TP_Patch2DA(get_pe_int row, get_pe_int "1", get_pe_int "0",
                          get_pe_int kit_name) ;
              TP_Patch2DA(get_pe_int row, get_pe_int "2", get_pe_int "0",
                          get_pe_int (string_of_int lower_index)) ;
              TP_Patch2DA(get_pe_int row, get_pe_int "3", get_pe_int "0",
                          get_pe_int (string_of_int mixed_index)) ;
              TP_Patch2DA(get_pe_int row, get_pe_int "4", get_pe_int "0",
                          get_pe_int (string_of_int help_index)) ;
              TP_Patch2DA(get_pe_int row, get_pe_int "5", get_pe_int "0",
                          get_pe_int abil_file) ;
              TP_Patch2DA(get_pe_int row, get_pe_int "6", get_pe_int "0",
                          get_pe_int (string_of_int prof_number)) ;
              TP_Patch2DA(get_pe_int row, get_pe_int "7", get_pe_int "0",
                          get_pe_int unused_class)], []) in
        TP_Copy ({copy_get_existing = true ;
                  copy_use_regexp = false ;
                  copy_use_glob = false ;
                  copy_file_list = ["kitlist.2da", "override"] ;
                  copy_patch_list = [patch] ;
                  copy_constraint_list = [] ;
                  copy_backup = true ;
                  copy_at_end = false ;
                  copy_save_inlined = false}) end in
''',
    '''  let kitlist_action number kit_name lower_index mixed_index help_index
                     abil_file prof_number unused_class filler_line =
    let append_to_kitlist = Printf.sprintf
                              "%d  %s %d %d %d %s %d %s"
                              number kit_name lower_index mixed_index
                              help_index abil_file prof_number unused_class in
    match filler_line with
    | None ->
        TP_Append("KITLIST.2DA",append_to_kitlist,[],true,false,0)
    | Some filler_line ->
        let filler_pattern = Printf.sprintf "^%s$" (Str.quote filler_line) in
        let patch =
          TP_PatchIf
            (PE_GT (get_pe_int "%SOURCE_SIZE%", get_pe_int "0"),
             (* no measureble performance impact on my machine with
              * conventional HDD - Wisp *)
             [TP_PatchStringTextually
                (Some true, Some false, filler_pattern, append_to_kitlist,
                 None)], []) in
        TP_Copy ({copy_get_existing = true ;
                  copy_use_regexp = false ;
                  copy_use_glob = false ;
                  copy_file_list = ["kitlist.2da", "override"] ;
                  copy_patch_list = [patch] ;
                  copy_constraint_list = [] ;
                  copy_backup = true ;
                  copy_at_end = false ;
                  copy_save_inlined = false}) in
''',
    "filler-row replacement",
)

tpaction = replace_once(
    tpaction,
    '''            let this_kit_number, exp = get_next_kit_number "KITLIST.2DA" in
''',
    '''            let this_kit_number, filler_line =
              get_next_kit_number "KITLIST.2DA" in
''',
    "filler-row result binding",
)

tpaction = replace_once(
    tpaction,
    '''                                    this_kit_prof_number k.unused_class exp in
''',
    '''                                    this_kit_prof_number k.unused_class
                                    filler_line in
''',
    "filler-row action argument",
)

tpaction_path.write_text(tpaction, encoding="utf-8")

doc_path = Path("doc/base.tex")
doc = doc_path.read_text(encoding="utf-8")
doc = replace_once(
    doc,
    r"If a row in \t{KITLIST.IDS} consists of a leading number followed",
    r"If a row in \t{KITLIST.2DA} consists of a leading number followed",
    "KITLIST documentation resource name",
)
doc_path.write_text(doc, encoding="utf-8")
