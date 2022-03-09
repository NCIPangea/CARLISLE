
def get_input_fastqs(wildcards):
    d = dict()
    d["R1"] = replicateName2R1[wildcards.replicate]
    d["R2"] = replicateName2R2[wildcards.replicate]
    return d

# check adapters
check_readaccess(config["adapters"])

rule trim:
    input:
        unpack(get_input_fastqs)
    output:
        R1 = join(RESULTSDIR,"tmp","trim","{replicate}.R1.trim.fastq.gz"),
        R2 = join(RESULTSDIR,"tmp","trim","{replicate}.R2.trim.fastq.gz"),
    params:
        adapters = config["adapters"],
    threads: getthreads("trim")
    envmodules:
        TOOLS["cutadapt"],
    shell:"""
set -exo pipefail
if [[ -d "/lscratch/$SLURM_JOB_ID" ]]; then 
    TMPDIR="/lscratch/$SLURM_JOB_ID"
else
    dirname=$(basename $(mktemp))
    TMPDIR="/dev/shm/$dirname"
    mkdir -p $TMPDIR
fi
cutadapt \\
--pair-filter=any \\
--nextseq-trim=2 \\
--trim-n \\
-n 5 -O 5 \\
-q 10,10 \\
-m 35:35 \\
-b file:{params.adapters} \\
-B file:{params.adapters} \\
-j {threads} \\
-o {output.R1} \\
-p {output.R2} \\
{input.R1} {input.R2}
"""

rule align:
    input:
        R1 = join(RESULTSDIR,"tmp","trim","{replicate}.R1.trim.fastq.gz"),
        R2 = join(RESULTSDIR,"tmp","trim","{replicate}.R2.trim.fastq.gz"),
        bt2 = join(BOWTIE2_INDEX,"ref.1.bt2")
    output:
        bam=join(RESULTSDIR,"tmp","bam","{replicate}.bam"),
        bai=join(RESULTSDIR,"tmp","bam","{replicate}.bam.bai"),
        bamflagstat=join(RESULTSDIR,"tmp","bam","{replicate}.bam.flagstat"),
        bamidxstats=join(RESULTSDIR,"tmp","bam","{replicate}.bam.idxstats"),
    params:
        replicate = "{replicate}",
        bowtie2_parameters = config["bowtie2_parameters"],
        bt2_base = join(BOWTIE2_INDEX,"ref"),
        pyscript = join(SCRIPTSDIR,"_filter_bam.py")
    threads: getthreads("align")
    envmodules:
        TOOLS["bowtie2"],
        TOOLS["samtools"],
    shell:"""
set -exo pipefail
if [[ -d "/lscratch/$SLURM_JOB_ID" ]]; then 
    TMPDIR="/lscratch/$SLURM_JOB_ID"
else
    dirname=$(basename $(mktemp))
    TMPDIR="/dev/shm/$dirname"
    mkdir -p $TMPDIR
fi
bowtie2 \\
    -p {threads} \\
    {params.bowtie2_parameters} \\
    -x {params.bt2_base}  \\
    -1 {input.R1} -2 {input.R2}  | \\
    samtools view -bS - |  \\
    samtools sort -T ${{TMPDIR}} -@{threads} -o {output.bam}
samtools index {output.bam}
samtools flagstat {output.bam} > {output.bamflagstat}
samtools idxstats {output.bam} > {output.bamidxstats}
"""

rule filter:
    input:
        bam=join(RESULTSDIR,"tmp","bam","{replicate}.bam"),
        bai=join(RESULTSDIR,"tmp","bam","{replicate}.bam.bai")
    output:
        bam=join(RESULTSDIR,"bam","{replicate}.bam"),
        bai=join(RESULTSDIR,"bam","{replicate}.bam.bai"),
        bamflagstat=join(RESULTSDIR,"bam","{replicate}.bam.flagstat"),
        bamidxstats=join(RESULTSDIR,"bam","{replicate}.bam.idxstats"),
    params:
        replicate = "{replicate}",
        bowtie2_parameters = config["bowtie2_parameters"],
        bt2_base = join(BOWTIE2_INDEX,"ref"),
        remove_duplicates = REMOVEDUP,
        fragment_len_filter = config["fragment_len_filter"],
        pyscript = join(SCRIPTSDIR,"_filter_bam.py")
    threads: getthreads("filter")
    envmodules:
        TOOLS["bowtie2"],
        TOOLS["samtools"],
        TOOLS["python37"],
        TOOLS["picard"]
    shell:"""
set -exo pipefail
if [[ -d "/lscratch/$SLURM_JOB_ID" ]]; then 
    TMPDIR="/lscratch/$SLURM_JOB_ID"
else
    dirname=$(basename $(mktemp))
    TMPDIR="/dev/shm/$dirname"
    mkdir -p $TMPDIR
fi
outbam_bn=$(basename {output.bam})
if [[ "{params.remove_duplicates}" == "Y" ]];then
    mkdir -p ${{TMPDIR}}/${{outbam_bn%.*}}_picardtmp

    java -Xmx100g -jar $PICARDJARPATH/picard.jar MarkDuplicates \\
    --INPUT={input.bam} \\
    --OUTPUT=${{TMPDIR}}/${{outbam_bn%.*}}.filtered.tmp1.bam \\
    --ASSUME_SORT_ORDER=coordinate \\
    --TMP_DIR=${{TMPDIR}}/${{outbam_bn%.*}}_picardtmp \\
    --CREATE_INDEX=true
    
    python {params.pyscript} --inputBAM ${{TMPDIR}}/${{outbam_bn%.*}}.filtered.tmp1.bam \\
    --outputBAM ${{TMPDIR}}/${{outbam_bn%.*}}.filtered.bam \\
    --fragmentlength {params.fragment_len_filter} \\
    --removemarkedduplicates

else

    python {params.pyscript} --inputBAM {input.bam} \\
    --outputBAM ${{TMPDIR}}/${{outbam_bn%.*}}.filtered.bam \\
    --fragmentlength {params.fragment_len_filter}

fi

samtools sort -T ${{TMPDIR}} -@{threads} -o {output.bam} ${{TMPDIR}}/${{outbam_bn%.*}}.filtered.bam
samtools flagstat {output.bam} > {output.bamflagstat}
samtools idxstats {output.bam} > {output.bamidxstats}
"""

rule create_bam2bg:
    input:
        bam = join(RESULTSDIR,"bam","{replicate}.bam"),
        bai = join(RESULTSDIR,"bam","{replicate}.bam.bai"),
        genomefile = join(BOWTIE2_INDEX,"ref.len"),
        spikein_len = join(BOWTIE2_INDEX,"spikein.len"),
        bamidxstats = join(RESULTSDIR,"bam","{replicate}.bam.idxstats"),
        spikein = SPIKED_GENOMEFA
    output:
        bg=join(RESULTSDIR,"bedgraph","{replicate}.bedgraph")
    params:
        replicate = "{replicate}",
        fragment_len_filter = config["fragment_len_filter"],
        spikein_scale = config["spikein_scale"]
    threads: getthreads("create_bam2bg")
    envmodules:
        TOOLS["bedtools"],
    shell:"""

set -exo pipefail
if [[ -d "/lscratch/$SLURM_JOB_ID" ]]; then 
    TMPDIR="/lscratch/$SLURM_JOB_ID"
else
    dirname=$(basename $(mktemp))
    TMPDIR="/dev/shm/$dirname"
    mkdir -p $TMPDIR
fi

if [[ "{input.spikein}" == "" ]];then
    spikein_scale=1
else
    spikein_readcount=$(while read a b;do awk -v a=$a '{{if ($1==a) {{print $3}}}}' {input.bamidxstats};done < {input.spikein_len} | awk '{{sum=sum+$1}}END{{print sum}}')
    spikein_scale=$(echo "{params.spikein_scale} / $spikein_readcount" | bc -l)


bn=$(basename {input.bam})
bedtools bamtobed -bedpe -i {input.bam} > ${{TMPDIR}}/${{bn%.*}}.bed
awk -v fl={params.fragment_len_filter}' {{ if ($1==$4 && $6-$2 < fl) {{print $0}}}}' ${{TMPDIR}}/${{bn%.*}}.bed > ${{TMPDIR}}/${{bn%.*}}.clean.bed
cut -f 1,2,6 ${{TMPDIR}}/${{bn%.*}}.clean.bed | sort -k1,1 -k2,2n -k3,3n > ${{TMPDIR}}/${{bn%.*}}.fragments.bed
bedtools genomecov -bg -scale $spikein_scale -i ${{TMPDIR}}/${{bn%.*}}.fragments.bed -g {input.genomefile} > {output.bg}
"""