# =============================================================================
# report_signoff.tcl -- emit the signoff reports for one corner.
#
# Crucially, report_timing is emitted with `-path_type full_clock_expanded` and
# default columns -- the exact layout tools/pd/pt_report_parser.py consumes.
# After the run, classify every violation with:
#
#     python3 tools/pd/pt_report_parser.py reports/*_setup.rpt reports/*_hold.rpt
#
# Args:
#   corner  -- corner name (for the output filenames)
#   check   -- max | min | both  (from load_corner)
#   outdir  -- directory for the .rpt files
# =============================================================================

proc report_signoff {corner check outdir} {
    file mkdir $outdir
    update_timing -full

    # ---- QoR one-liner (feeds flow_metrics-style scorecards) --------------
    redirect $outdir/${corner}_qor.rpt { report_qor }
    redirect $outdir/${corner}_constraint.rpt {
        report_constraint -all_violators -significant_digits 4
    }

    # ---- worst paths, in the parser's expected format ---------------------
    if {$check eq "max" || $check eq "both"} {
        redirect $outdir/${corner}_setup.rpt {
            report_timing -delay_type max \
                -path_type full_clock_expanded \
                -max_paths 200 -nworst 5 -slack_lesser_than 0.5 \
                -sort_by slack -significant_digits 4
        }
    }
    if {$check eq "min" || $check eq "both"} {
        redirect $outdir/${corner}_hold.rpt {
            report_timing -delay_type min \
                -path_type full_clock_expanded \
                -max_paths 200 -nworst 5 -slack_lesser_than 0.5 \
                -sort_by slack -significant_digits 4
        }
    }

    # ---- compact summary the OpenSTA-style scorecard also understands -----
    redirect $outdir/${corner}_summary.rpt {
        puts "corner $corner"
        puts "report_worst_slack -max (Setup)"
        puts "worst slack [get_attribute [get_timing_paths -delay_type max] slack]"
        puts "report_worst_slack -min (Hold)"
        puts "worst slack [get_attribute [get_timing_paths -delay_type min] slack]"
    }
    puts "\[report_signoff\] $corner -> $outdir/${corner}_{setup,hold,qor}.rpt"
}
