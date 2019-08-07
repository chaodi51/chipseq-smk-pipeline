import os
from pipeline_util import fastq_paths, trimmed_fastq_sample_names, trim_galore_file_suffix

ruleorder: trim_paired_fastq > trim_single_fastq
localrules: step2_trim_fastq_results, multiqc_trimmed_fastq

# def step1_trim_fastq_results_input_fun():
#     if bool(config['trim_reads']):
#         return dict(multiqc_fastq='multiqc/trimmed/multiqc.html')
#     else:
#         return {}

rule step2_trim_fastq_results:
    input:
        multiqc_fastq='multiqc/trimmed/multiqc.html'



# TODO: multiqc: rename for match original files (from trimgalore reports) with
#  fastqc files

rule trim_single_fastq:
    input: f"{config['fastq_dir']}/{{sample}}.{config['fastq_ext']}"
    output:
        f"trimmed/{{sample}}_trimmed.{trim_galore_file_suffix(config)}",
        f"trimmed/{{sample}}.{config['fastq_ext']}_trimming_report.txt"
    threads: 4
    log: 'logs/trimmed/{sample}.log'
    resources:
        threads=4,
        mem=16, mem_ram=12,
        time=60 * 120
    conda: 'envs/bio.env.yaml'
    # params:
    #     extra = "--cores {threads}" # "--illumina -q 20"
    # wrapper: '0.36.0/bio/trim_galore/se' # only 0.4.3 trim galore version
    conda: 'envs/bio.env.yaml'
    params:
        extra=lambda wildcards, threads: f"--cores {threads}",  # "--illumina -q 20"
        out_dir="trimmed"
    shell:
        "trim_galore {params.extra} -o {params.out_dir} {input} &> {log}"
        # " && mv trimmed/{wildcards.sample}"
        # f"_trimmed.{trim_galore_file_suffix()}"
        # " {output} &>> {log}"

# MultiQC handles "_trimmed" suffix, so it could combine cutadapt (trimgalore)
# and fastqc reports correctly for single-end reads. Let's rename paired-end
# reads to *_1_trimmed.fq.gz, *_2_trimmed.fq.gz
rule trim_paired_fastq:
    input:
        first=f"{config['fastq_dir']}/{{sample}}_1.{config['fastq_ext']}",
        second=f"{config['fastq_dir']}/{{sample}}_2.{config['fastq_ext']}"
    output:
        # f"trimmed/{{sample}}_1_val_1.{trim_galore_file_suffix()}",
        fq1 = f"trimmed/{{sample}}_1_trimmed.{trim_galore_file_suffix(config)}",
        fq1_rep = f"trimmed/{{sample}}_1.{config['fastq_ext']}_trimming_report.txt",
        # f"trimmed/{{sample}}_2_val_2.{trim_galore_file_suffix()}",
        fq2 = f"trimmed/{{sample}}_2_trimmed.{trim_galore_file_suffix(config)}",
        fq2_rep = f"trimmed/{{sample}}_2.{config['fastq_ext']}_trimming_report.txt"
    threads: 4
    log: 'logs/trimmed/{sample}.log'
    resources:
        threads=4,
        mem=16, mem_ram=12,
        time=60 * 120
    # wrapper: '0.36.0/bio/trim_galore/pe' only 0.4.3 trim galore version
    params:
        extra=lambda wildcards, threads: f"--cores {threads}",  # "--illumina -q 20"
        out_dir="trimmed"
    conda: 'envs/bio.env.yaml'
    shell:
        "trim_galore {params.extra} --paired -o {params.out_dir} {input} &> {log} &&"
        " mv trimmed/{wildcards.sample}_1"f"_val_1.{trim_galore_file_suffix(config)}"" {output.fq1} &>> {log} &&"
        " mv trimmed/{wildcards.sample}_2"f"_val_2.{trim_galore_file_suffix(config)}"" {output.fq2} &>> {log}"

rule trimmed_fastqc:
    input: f"trimmed/{{any}}.{trim_galore_file_suffix(config)}"
    output:
        html='qc/trimmed/fastqc/{any}_fastqc.html',
        zip='qc/trimmed/fastqc/{any}_fastqc.zip'
    log: 'logs/trimmed/fastqc/{any}.log'
    wildcard_constraints: any="[^/]+"

    resources:
        threads=1,
        mem=8, mem_ram=4,
        time=60 * 120

    # https://bitbucket.org/snakemake/snakemake-wrappers/src/0.31.1/bio/fastqc/
    wrapper: '0.36.0/bio/fastqc'


rule multiqc_trimmed_fastq:
    input:
        expand(
            'qc/trimmed/fastqc/{trimmed_sample}_fastqc.zip',
            trimmed_sample=trimmed_fastq_sample_names(config)
        ),
        expand(
            'trimmed/{fastq_file}_trimming_report.txt',
            fastq_file=[os.path.basename(p) for p in fastq_paths(config)]
        ),

    output: 'multiqc/trimmed/multiqc.html'
    log: 'multiqc/trimmed/multiqc.log'

    wrapper: '0.36.0/bio/multiqc'
