# Milestone 2 / Q8: find out WHERE the setup failures are.
#
# quartus_sta's default flow emits only summary tables, which is why M0 could
# show -13 ns of slack but not which paths caused it. This script reports the
# worst paths and attributes failing endpoints to entities, so we can test the
# docs/08 section 8.8 hypothesis that they are all clock-enable-gated (and so
# have 4 clk_sys cycles in hardware, not the 1 that STA assumes).
#
# Every section is wrapped in `catch`: this runs after a ~40 minute fit, so a
# Tcl slip in a late section must not throw away the earlier output.
#
# Usage, from the project directory:
#   quartus_sta -t ../tools/timing-report.tcl <revision>

set rev [lindex $quartus(args) 0]
if {$rev eq ""} { set rev "jaguar_pocket" }

project_open -revision $rev $rev
create_timing_netlist
read_sdc
update_timing_netlist

proc section {title body} {
    puts "\n================ $title ================"
    if {[catch {uplevel 1 $body} err]} {
        puts "  (section failed: $err)"
    }
}

section "CLOCKS" {
    foreach_in_collection c [get_clocks] {
        set nm [get_clock_info -name $c]
        set pd [get_clock_info -period $c]
        if {$pd > 0} {
            puts [format "  %-70s %10.4f MHz  (%.4f ns)" $nm [expr {1000.0/$pd}] $pd]
        } else {
            puts [format "  %-70s period 0" $nm]
        }
    }
}

section "WORST SETUP SLACK PER CLOCK" {
    foreach_in_collection c [get_clocks] {
        set nm [get_clock_info -name $c]
        if {[catch {set ps [get_timing_paths -setup -npaths 1 -to_clock $nm]} e]} {
            puts [format "  %-70s (no paths)" $nm]
            continue
        }
        foreach_in_collection p $ps {
            puts [format "  %-70s %9.3f ns" $nm [get_path_info -slack $p]]
        }
    }
}

section "WORST 40 SETUP PATHS" {
    set i 0
    foreach_in_collection p [get_timing_paths -setup -npaths 40 -detail path_only] {
        incr i
        set s [get_path_info -slack $p]
        set from "?"
        set to   "?"
        catch { set from [get_node_info -name [get_path_info -from $p]] }
        catch { set to   [get_node_info -name [get_path_info -to   $p]] }
        puts [format "%3d  slack %9.3f" $i $s]
        puts "     from $from"
        puts "     to   $to"
    }
}

# The question Q8 actually asks: is the damage inside CE-gated console logic,
# or in the SDRAM controller / wrapper, which really are single-cycle?
section "FAILING ENDPOINTS BY ENTITY" {
    array set hist {}
    set total 0
    foreach_in_collection p [get_timing_paths -setup -npaths 3000 -detail path_only] {
        set s [get_path_info -slack $p]
        if {$s >= 0} { continue }
        set to ""
        if {[catch { set to [get_node_info -name [get_path_info -to $p]] }]} { continue }
        set parts [split $to "|"]
        # Drop the leading core_top|jaguar_top|jaguar levels, which every path
        # shares, then keep the next four. Keying on 3 absolute levels made the
        # whole histogram collapse into a single row.
        set key [join [lrange $parts 3 6] "|"]
        if {$key eq ""} { set key [join [lrange $parts 0 end-1] "|"] }
        if {[info exists hist($key)]} {
            set hist($key) [expr {$hist($key) + 1}]
        } else {
            set hist($key) 1
        }
        incr total
    }
    puts "  $total failing endpoints sampled"
    # plain-Tcl sort by count, descending -- no `apply`, which needs global scope
    set rows {}
    foreach k [array names hist] { lappend rows [list $hist($k) $k] }
    foreach r [lsort -integer -index 0 -decreasing $rows] {
        puts [format "  %6d  %s" [lindex $r 0] [lindex $r 1]]
    }
}

# Every failing ENDPOINT (one worst path each), not just the worst 3000 paths.
# The 3000-path sample above only ever showed the blitter, which hid whether
# any single-cycle logic fails too. Grouped by 3 and by
# 5 hierarchy levels below jaguar_top, with the worst slack per group.
section "ALL FAILING ENDPOINTS BY MODULE" {
    foreach depth {3 5} {
        array unset cnt; array unset worst
        set total 0
        foreach_in_collection p [get_timing_paths -setup -npaths 200000 -nworst 1 -less_than_slack 0 -detail path_only] {
            set s [get_path_info -slack $p]
            set to ""
            if {[catch { set to [get_node_info -name [get_path_info -to $p]] }]} { continue }
            set parts [split $to "|"]
            set key [join [lrange $parts 0 [expr {$depth + 1}]] "|"]
            regsub -all {:[A-Za-z0-9_]+} $key "" key
            if {[info exists cnt($key)]} {
                incr cnt($key)
                if {$s < $worst($key)} { set worst($key) $s }
            } else { set cnt($key) 1; set worst($key) $s }
            incr total
        }
        puts "  --- depth $depth: $total failing endpoints ---"
        set rows {}
        foreach k [array names cnt] { lappend rows [list $cnt($k) $worst($k) $k] }
        foreach r [lsort -integer -index 0 -decreasing $rows] {
            puts [format "  %7d  worst %8.3f  %s" [lindex $r 0] [lindex $r 1] [lindex $r 2]]
        }
    }
}

# Failing paths that END outside the CE-gated console (Tom/Jerry netlist logic),
# with where they START. Single-cycle logic -- the SDRAM controller above all --
# cannot be excused the way CE-gated paths can, so each one needs a reason.
section "NON-CE-GATED FAILING PATHS: FROM -> TO" {
    set n 0
    foreach_in_collection p [get_timing_paths -setup -npaths 200000 -nworst 1 -less_than_slack 0 -detail path_only] {
        set to ""; set from ""
        if {[catch { set to [get_node_info -name [get_path_info -to $p]] }]} { continue }
        if {[string match "*|_tom:*" $to] || [string match "*|_j_jerry:*" $to]} { continue }
        catch { set from [get_node_info -name [get_path_info -from $p]] }
        regsub -all {:[A-Za-z0-9_]+} $from "" from
        regsub -all {:[A-Za-z0-9_]+} $to "" to
        regsub {^core_top\|jaguar_top\|} $from "" from
        regsub {^core_top\|jaguar_top\|} $to "" to
        puts [format "  %8.3f  %s\n            <- %s" [get_path_info -slack $p] $to $from]
        incr n
    }
    puts "  $n non-CE-gated failing endpoints"
}

# report_unconstrained_paths does not exist in Quartus 21.1's quartus_sta
# (it failed with `invalid command name`), so use the metastability/ucp report.
section "UNCONSTRAINED PATHS" {
    report_ucp -summary -panel_name "Unconstrained"
}

# FAST-CORNER SETUP. Across six hardware-tested builds,
# slow-corner worst slack did not separate working from broken bitstreams, but
# fast-corner setup TNS did (good: -760..-996 / -159..-276 ns at 85C/0C; bad:
# -1129..-1157 / -337..-390). A path that fails even in the fast model is
# genuinely too long for silicon. Emit a parsable score line per fast
# condition, then the failing endpoints by module and the worst paths.
section "FAST-CORNER SETUP" {
    set conds {}
    foreach c [get_available_operating_conditions] {
        if {[string match -nocase "*fast*" $c]} { lappend conds $c }
    }
    foreach c $conds {
        set_operating_conditions $c
        update_timing_netlist
        set tns 0.0; set nfail 0
        array unset cnt; array unset worst
        foreach_in_collection p [get_timing_paths -setup -npaths 200000 -nworst 1 -less_than_slack 0 -detail path_only] {
            set s [get_path_info -slack $p]
            set tns [expr {$tns + $s}]
            incr nfail
            set to ""
            if {[catch { set to [get_node_info -name [get_path_info -to $p]] }]} { continue }
            set parts [split $to "|"]
            set key [join [lrange $parts 0 6] "|"]
            regsub -all {:[A-Za-z0-9_]+} $key "" key
            if {[info exists cnt($key)]} {
                incr cnt($key)
                if {$s < $worst($key)} { set worst($key) $s }
            } else { set cnt($key) 1; set worst($key) $s }
        }
        puts [format "FASTCORNER_SCORE %s tns=%.3f failing_endpoints=%d" $c $tns $nfail]
        set rows {}
        foreach k [array names cnt] { lappend rows [list $cnt($k) $worst($k) $k] }
        foreach r [lsort -integer -index 0 -decreasing $rows] {
            puts [format "  %7d  worst %8.3f  %s" [lindex $r 0] [lindex $r 1] [lindex $r 2]]
        }
        puts "  --- worst 30 paths at $c ---"
        foreach_in_collection p [get_timing_paths -setup -npaths 30 -detail path_only] {
            set from "?"; set to "?"
            catch { set from [get_node_info -name [get_path_info -from $p]] }
            catch { set to   [get_node_info -name [get_path_info -to   $p]] }
            regsub -all {:[A-Za-z0-9_]+} $from "" from
            regsub -all {:[A-Za-z0-9_]+} $to "" to
            puts [format "  %8.3f  %s\n            <- %s" [get_path_info -slack $p] $to $from]
        }
    }
}

project_close
