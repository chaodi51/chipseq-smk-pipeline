#!/usr/bin/env python
import os
import re
from glob import glob

MACS2_SUFFIX = 'q0.05'
MACS2_PARAMS = '-q 0.05'
MACS2_PARAMS_ATAC_SEQ = '-q 0.05 -f BAMPE --nomodel --nolambda -B --call-summits'
MACS2_PARAMS_BROAD = '--broad --broad-cutoff 0.05'

SICER_FRAGMENT = '150'

SPAN_PARAMS = ''
SPAN_PARAMS_ATAC_SEQ = '--fragment 0'

print('CONFIG\n{}'.format('\n'.join(['{}: {}'.format(k, v) for k, v in config.items()])))


def fastq_files():
    return glob(os.path.join(config['fastq_dir'], '*.f*q'))


def fastq_names():
    return [os.path.splitext(os.path.basename(fastq_file))[0] for fastq_file in fastq_files()]


def fastq_common_names_paired():
    basenames = {os.path.splitext(fastq_file)[0] for fastq_file in fastq_files()}
    paired_candidates = [basename[:-2] for basename in basenames if basename[-2:] == '_1']
    return [os.path.basename(common_name) for common_name in paired_candidates if common_name + '_2' in basenames]


def fastq_names_single():
    common_names = fastq_common_names_paired()
    return [fastq_name for fastq_name in fastq_names()
            if fastq_name[-2:] not in ['_1', '_2'] or fastq_name[:-2] not in common_names]


def fastq_aligned_names():
    return fastq_common_names_paired() + fastq_names_single()


def macs_species(genome):
    """Convert genome to macs2 species encoding"""
    if re.match('^hg[0-9]+$', genome):
        return 'hs'
    elif re.match('^mm[0-9]+$', genome):
        return 'mm'
    raise Exception('Unknown species {}'.format(genome))


def effective_genome_fraction(genome, chrom_sizes_path):
    """From MACS2 documentation:
    The default hs 2.7e9 is recommended for UCSC human hg18 assembly.
    Here are all precompiled parameters for effective genome size:
    hs: 2.7e9
    mm: 1.87e9
    ce: 9e7
    dm: 1.2e8"""
    with open(chrom_sizes_path, 'r') as chrom_sizes:
        chrom_length = sum([int(line.split('\t')[1]) for line in chrom_sizes if 'chr_' not in line])
    if genome.startswith('mm'):
        size = 1.87e9
    elif genome.startswith('hg'):
        size = 2.7e9
    else:
        raise Exception('Unknown species {}'.format(genome))
    return size / chrom_length


workdir: config['work_dir']

rule download_chrom_sizes:
    output: '{}.chrom.sizes'.format(config['genome'])
    shell:
         'wget -O {output} http://hgdownload.cse.ucsc.edu/goldenPath/{config[genome]}/bigZips/{config[genome]}.chrom.sizes'

rule download_fa:
    output: os.path.join(config['work_dir'], directory('fa'))
    shell: "rsync -avz --partial --exclude='*.txt' " \
           'rsync://hgdownload.cse.ucsc.edu/goldenPath/{config[genome]}/chromosomes/ {output} && ' \
           'gunzip -f {output}/*.fa.gz'

rule index_bowtie:
    input: directory('fa')
    output: os.path.join(config['work_dir'], directory('indexes'))
    params:
          files_list=lambda wildcards: ','.join(glob('fa/*.fa')),
          target='indexes/{genome}'.format(genome=config['genome'])
    conda: 'envs/bio.env.yaml'
    shell: 'mkdir -p {output} && bowtie-build {params.files_list} {params.target}'

rule fastqc:
    input: os.path.join(config['fastq_dir'], '{sample}.fastq')
    output:
          html='qc/fastqc/{sample}_fastqc.html',
          zip='qc/fastqc/{sample}_fastqc.zip'
    log: 'logs/fastqc/{sample}.log'
    wrapper: '0.31.1/bio/fastqc'

rule multiqc_fastq:
    input: expand('qc/fastqc/{sample}_fastqc.zip', sample=fastq_names())
    output: 'multiqc/fastqc/multiqc.html'
    log: 'multiqc/fastqc/multiqc.log'
    wrapper: '0.31.1/bio/multiqc'

rule align_single_sam:
    input:
         fastq=os.path.join(config['fastq_dir'], '{sample}.fastq'),
         indexes=rules.index_bowtie.output
    output: temp('bams/{sample}.sam')
    threads: 8
    log: 'logs/bowtie/{sample}.log'
    shell: 'bowtie -p {threads} -St -m 1 -v 3 --best --strata ' \
           '--index {input.indexes}/{config[genome]} {input.fastq} {output}'

rule align_paired_sam:
    input:
         first=os.path.join(config['fastq_dir'], '{sample}_1.fastq'),
         second=os.path.join(config['fastq_dir'], '{sample}_2.fastq'),
         indexes=rules.index_bowtie.output
    output: temp('bams/{sample}.sam')
    threads: 8
    log: 'logs/bowtie/{sample}.log'
    shell: 'bowtie -p {threads} -St -m 1 -v 3 --best --strata --index {input.indexes}/{config[genome]} ' \
           '-1 {input.first} -2 {input.second} {output}'

rule sam_to_bam:
    input: 'bams/{sample}.sam'
    output: 'bams/{sample}.bam'
    conda: 'envs/bio.env.yaml'
    shell: 'samtools view -bS {input} -o {output}.unsorted; ' \
           'samtools sort {output}.unsorted -o {output}; ' \
           'rm {output}.unsorted;'


rule index_bams:
    input: '{anywhere}/{sample}.bam'
    output: '{anywhere}/{sample, [^/]*}.bam.bai'
    wrapper: '0.31.1/bio/samtools/index'

rule download_phantompeakqualtools:
    output: directory('bin/phantompeakqualtools')
    params:
          targz='phantompeakqualtools.tar.gz'
    shell: 'cd bin; ' \
           'curl --location ' \
           'https://storage.googleapis.com/google-code-archive-downloads/v2/' \
           'code.google.com/phantompeakqualtools/ccQualityControl.v.1.1.tar.gz ' \
           '--output {params.targz}; ' \
           'tar xvf {params.targz}'

rule bam_qc_phantom:
    input:
         ppqt_dir=rules.download_phantompeakqualtools.output,
         bam='bams/{sample}.bam'
    output: 'bams/qc/{sample}.phantom.tsv'
    params:
          run_spp=lambda wildcards, input: os.path.join(str(input.ppqt_dir), 'run_spp.R')
    shell: 'Rscript {params.run_spp} -c={input.bam} -savp -out={output} -rf'

rule bam_to_pileup:
    input: 'bams/{sample}.bam'
    output: temp('bams/pileup/{sample}.bed')
    conda: 'envs/bio.env.yaml'
    shell: 'bedtools bamtobed -i {input} > {output}'

rule bam_qc_pbc_nrf:
    input: rules.bam_to_pileup.output
    output: 'bams/qc/{sample}.pbc_nrf.tsv'
    params:
          tmp_dir='tmp'
    shell: '''
mkdir -p {params.tmp_dir} &&
(T=$'\\t'
>&2 echo "TotalReadPairs${{T}}DistinctReadPairs${{T}}OneReadPair${{T}}TwoReadPairs${{T}}\
NRF=Distinct/Total${{T}}PBC1=OnePair/Distinct${{T}}PBC2=OnePair/TwoPair"

cat {input} | \
    sort -k1,1 -k3,3n -k2,2n -k6,6 -T {params.tmp_dir} | \
    awk -v OFS='\\t' '{{print $1,$2,$3,$6}}' | uniq -c | \
    awk 'BEGIN{{mt=0;m0=0;m1=0;m2=0}}
    ($1==1){{m1=m1+1}} ($1==2){{m2=m2+1}} {{m0=m0+1}} {{mt=mt+$1}}
    END{{
        if (mt!=0){{m0_t=m0/mt}} else {{m0_t=-1.0}};
        if (m0!=0){{m1_0=m1/m0}} else {{m1_0=-1.0}};
        if (m2!=0){{m1_2=m1/m2}} else {{m1_2=-1.0}};
        printf "%d\\t%d\\t%d\\t%d\\t%f\\t%f\\t%f\\n",mt,m0,m1,m2,m0_t,m1_0,m1_2;
    }}') > {output}
    '''

rule multiqc_bowtie:
    input: expand('logs/bowtie/{sample}.log', sample=fastq_aligned_names())
    output: 'multiqc/bowtie/multiqc.html'
    log: 'multiqc/bowtie/multiqc.log'
    wrapper: '0.31.1/bio/multiqc'

rule bam_stats:
    input: 'cleaned/{sample}.bam'
    output: 'qc/samtools_stats/{sample}_samtools_stats.txt'
    wrapper: '0.31.1/bio/samtools/stats'

rule bam_stats_multiqc:
    input: expand('qc/samtools_stats/{sample}_samtools_stats.txt', sample=fastq_aligned_names())
    output: 'multiqc/samtools_stats/multiqc.html'
    log: 'multiqc/samtools_stats/multiqc.log'
    wrapper: '0.31.1/bio/multiqc'

rule sort_bams:
    input: 'bams/{sample}.bam'
    output: 'sorted/{sample}.bam'
    threads: 8
    wrapper: '0.31.1/bio/samtools/sort'

rule remove_duplicates:
    input: 'sorted/{sample}.bam'
    output:
          bam='deduplicated/{sample}.bam',
          metrics='qc/picard/{sample}.txt'
    log: 'deduplicated/{sample}.log'
    params: 'REMOVE_DUPLICATES=True'
    wrapper: '0.31.1/bio/picard/markduplicates'

rule bam2bw:
    input:
         bam='bams/{filename}.bam',
         bai='bams/{filename}.bam.bai'
    output: 'bw/{filename, [^/]*}.bw'
    conda: 'envs/deeptools.env.yaml'
    threads: 8
    shell: 'bamCoverage -b {input.bam} -p {threads} -o {output}'

rule call_peaks_macs2:
    input: 'bams/{sample}.bam'
    output: 'macs2_{macs2_suffix}/{sample}_{macs2_suffix}_peaks.{type}Peak'
    params:
          macs2_params=config.get('macs2_params', MACS2_PARAMS),
          species=macs_species(config['genome']),
          outdir=lambda wildcards, output: os.path.dirname(str(output[0]))
    conda: 'envs/py27.env.yaml'
    log: 'macs2_{macs2_suffix}/{sample}_{macs2_suffix}_macs2_{type}.log'
    shell: 'macs2 callpeak -t {input} --outdir {params.outdir} ' \
           '-n {wildcards.sample}_{wildcards.macs2_suffix} -g {params.species} ' \
           '{params.macs2_params}'

rule call_peaks_sicer:
    input:
         bed='bams/pileup/{sample}.bed',
         chrom_sizes=rules.download_chrom_sizes.output
    output: 'sicer/{sample}-W{width}-G{gap}-E{escore}.scoreisland'
    params:
          input_filename=lambda wildcards, input: os.path.basename(str(input.bed)),
          fragment=config.get('sicer_fragment', SICER_FRAGMENT),
          effective_genome_fraction=lambda wildcards: effective_genome_fraction(
              config['genome'], str(rules.download_chrom_sizes.output))
    conda: 'envs/py27.env.yaml'
    log: 'sicer/{sample}-W{width}-G{gap}-E{escore}_sicer.log'
    shell: 'SICER-rb.sh bams/pileup {params.input_filename} sicer {config[genome]} ' \
           '1 {wildcards.width} {params.fragment} {params.effective_genome_fraction} {wildcards.gap} {wildcards.escore}'

rule download_span:
    output: 'bin/span-0.11.0.jar'
    shell: 'wget -O {output} https://download.jetbrains.com/biolabs/span/span-0.11.0.4882.jar'

rule call_peaks_span:
    input:
         span=rules.download_span.output,
         chrom_sizes=rules.download_chrom_sizes.output,
         bam='bams/{sample}.bam'
    params:
         span_params=config.get('span_params', SPAN_PARAMS)
    output: 'span/{sample}_{bin}_{fdr}_{gap}.peak'
    threads: 8
    log: 'span/logs/{sample}_{bin}_{fdr}_{gap}.log'
    shell: 'java -Xmx8G -jar {input.span} analyze -t {input.bam} --chrom.sizes {input.chrom_sizes} ' \
           '--peaks {output} --model {wildcards.sample}_{wildcards.bin}.span --workdir span --threads {threads} ' \
           '--bin {wildcards.bin} --fdr {wildcards.fdr} --gap {wildcards.gap} {params.span_params}'

rule all:
    input:
         multiqc_fastq='multiqc/fastqc/multiqc.html',
         multiqc_bowtie='multiqc/bowtie/multiqc.html',
         multiqc_samtools_stats='multiqc/samtools_stats/multiqc.html',
         bws=expand('bw/{sample}.bw', sample=fastq_aligned_names()),
         bam_qc=expand('bams/qc/{sample}.phantom.tsv', sample=fastq_aligned_names()),
         bam_qc_pbc=expand('bams/qc/{sample}.pbc_nrf.tsv', sample=fastq_aligned_names()),
         bams_deduplicated=expand('deduplicated/{sample}.bam', sample=fastq_aligned_names()),
         macs2_peaks=expand('macs2_{macs2_suffix}/{sample}_{macs2_suffix}_peaks.narrowPeak',
                            sample=fastq_aligned_names(),
                            macs2_suffix=config.get('macs2_suffix', MACS2_SUFFIX)),
         sicer_peaks=expand('sicer/{sample}-W200-G600-E100.scoreisland', sample=fastq_aligned_names()),
         span_peaks=expand('span/{sample}_100_0.01_5.peak', sample=fastq_aligned_names())
