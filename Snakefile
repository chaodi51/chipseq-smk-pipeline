from pipeline_util import *

configfile: "config.yaml"
workdir: config['work_dir']


include: "rules/raw_qc.smk"
include: "rules/trim_fastq.smk"
include: "rules/alignment.smk"
include: "rules/filter_aligned_reads.smk"
include: "rules/reads_coverage.smk"
include: "rules/bam_quality_metrics.smk"
include: "rules/macs2.smk"
include: "rules/sicer.smk"
include: "rules/span.smk"

wildcard_constraints:
    sample="[^/]+"

localrules: all

if not os.path.exists(config['fastq_dir']):
    raise ValueError(f"Reads directory not exists: {config['fastq_dir']}")

rule all:
    input:
        # Reads qc
        rules.all_raw_qc_results.input,

        # Optional reads trimming, this option is controlled by setting: config[trim_reads]
        *([] if not is_trimmed(config) else rules.all_trim_fastq_results.input),

        # Alignment
        rules.all_alignment_results.input,

        # Filter only aligned reads: not all peak callers capable to exclude
        # unaligned reads or reads aligned with bad quality
        # Optionally deduplicated bams and save to 'deduplicated' folder
        rules.all_filter_aligned_reads_results.input,

        # Visualization
        rules.all_reads_coverage_results.input,

        # Optional: Quality metrics
        rules.all_bam_quality_metrics_results.input,

        # macs2
        rules.all_macs2_results.input,

        # sicer
        rules.all_sicer_results.input,

        # span
        rules.all_span.input,
        rules.all_span_tuned.input
