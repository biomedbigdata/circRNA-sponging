#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/circrnasponging
========================================================================================
 nf-core/circrnasponging Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/circrnasponging
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/circrnasponging 

    Mandatory arguments:
      --samplesheet [file]		Path to samplesheet (must be surrounded with quotes)
      --out_dir [file]			The output directory where the results will be saved
      --species [str]			Species name in 3 letter code (hsa for human, mmu for mouse)
      --genome_version [str]    Genome version that will be used for mapping e.g. for human hg19 or hg38
      --miRNA_adapter [str] 		miRNA adapter used for trimming
      -profile [str]           	 	Configuration profile to use. Can use multiple (comma separated)
                                      	Available: conda, docker, singularity, test, awsbatch, <institute> and more

      --fasta [file] 			Path to genome fasta (must be surrounded with quotes)
      --gtf [file]			Path to gtf file (must be surrounded with quotes)
      --gene_pred [file]		Path to gene annotation (must be surrounded with quotes)
      --mature_fasta [file]		Path to mature miRNA fasta (must be surrounded with quotes)
      --mature_other_fasta [file]	Path to mature miRNA fasta of related species (must be surrounded with quotes)
      --hairpin_fasta [file]		Path to miRNA hairpin fasta (must be surrounded with quotes)
      SPONGE:
      Apply target scan symbols directly:
        --target_scan_symbols [file]    Path to target scan symbols for SPONGE analysis
      Give one of the following options to create target scan symbols also using miranda/tarpmir
        --miRTarBaseData [file]     Path to miRTarBase dataset
        --TargetScanData [file]     Path to TargetScan dataset

    Options:
      --miRNA_raw_counts [file]		Path to tabulated raw miRNA counts (must be surrounded with quotes)
      --single_end [bool]            	Specifies that the total RNA input is single-end reads
      --sample_group	[file]		File specifying partitioning of samples into groups (must be surrounded with quotes)
      --read_threshold [real]		Positive. Read counts under this threshold are considered to be low expressed
      --sample_percentage [real]	Between 0 and 1. Minimum percentage of samples that should have no low expression
      --circRNA_only [bool]  		Run only circRNA analysis, don't run miRNA analysis
      --database_annotation [bool]  Annotate circRNA hits with circBase data
        --offline_circ_db [file]      File containing downloaded circBase entries for offline access to the database
      --differential_expression [bool]  Enable differential expression analysis using DESeq2 on all given RNA-seq data and circRNA only
   """.stripIndent() 
}

def get_circRNA_paths(LinkedHashMap row) {
    def array = []
    if (!file(row.totalRNA1).exists()) {
        exit 1, "Error: Fastq file does not exist!\n${row.totalRNA1}"
    }
    if (params.single_end) {
        array = [ row.sample, [ file(row.totalRNA1) ] ]
    } else {
        if (!file(row.totalRNA2).exists()) {
             exit 1, "Error: Fastq file does not exist!\n${row.totalRNA2}"
        }
        array = [ row.sample, [ file(row.totalRNA1), file(row.totalRNA2) ] ]
    }
    if (params.differential_expression){
        if (!row.containsKey("condition")) {
            exit 1, "Error: Condition marker missing!"
        }
    }
    return array
}

def get_miRNA_paths(LinkedHashMap row) {
    def array = []
    if (!file(row.smallRNA).exists()) {
        exit 1, "Error: FastQ file does not exist!\n${row.smallRNA}"
    }
    array = [ row.sample, [ file(row.smallRNA) ] ]
    return array
}

def check_input(){
    if (!params.genome_version) {
        if (params.database_annotation){
            exit 1, "Error: genome version not specified, which is mandatory for database annotation"
        }
        if (params.differential_expression){
            exit 1, "Error: genome version not specified, which is mandatory for differential expression analysis"
        }
    }
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * CREATE A CHANNEL FOR INPUT READ FILES
 */
ch_totalRNA_reads1=Channel.fromPath(params.samplesheet)
   .splitCsv( header:true, sep:'\t')
   .map { get_circRNA_paths(it) }
ch_totalRNA_reads2=Channel.fromPath(params.samplesheet)
   .splitCsv( header:true, sep:'\t')
   .map { get_circRNA_paths(it) }

ch_fasta = Channel.value(file(params.fasta))
ch_gtf = Channel.value(file(params.gtf))

/*
* CHECK INPUT OPTIONS
*/
check_input()

/*
* GENERATE STAR INDEX IN CASE IT IS NOT ALREADY PROVIDED
*/
process generate_star_index{
    label 'process_high'
    publishDir "${params.out_dir}/", mode: params.publish_dir_mode

    input:
    file(fasta) from ch_fasta
    file(gtf) from ch_gtf            
    
    output:
    file("star_index") into generated_star_index
                      
    when: (params.STAR_index == null)

    script:
    """
    echo "star index is running"
    mkdir star_index
      
    STAR \\
    --runMode genomeGenerate \\
    --runThreadN 8 \\
    --sjdbGTFfile $gtf \\
    --genomeDir star_index/ \\
    --genomeFastaFiles $fasta 
    """
}

/*
* GENERATE SALMON INDEX FOR GIVEN ORGANISM
*/
process generate_salmon_index {
    label 'process_high'
    publishDir "${params.out_dir}/", mode: params.publish_dir_mode

    output:
    file("salmon_index") into generated_salmon_index

    when: (params.SALMON_index == null && params.transcriptome != null)

    script:
    """
    salmon index -t $params.transcriptome -i salmon_index
    """
}

ch_star_index = params.STAR_index ? Channel.value(file(params.STAR_index)) : generated_star_index

ch_salmon_index = params.SALMON_index ? Channel.value(file(params.SALMON_index)) : generated_salmon_index

/*
* PERFORM READ MAPPING OF totalRNA SAMPLES USING STAR
*/
process STAR {
    label 'process_high'
    publishDir "${params.out_dir}/samples/${sampleID}/circRNA_detection/", mode: params.publish_dir_mode
    
    input:
    set val(sampleID), file(reads) from ch_totalRNA_reads1
    file star_index from ch_star_index

    output:
    tuple val(sampleID), file("Chimeric.out.junction") into chimeric_junction_files

    script:
    """
    STAR --chimSegmentMin 10 --runThreadN 10 --genomeDir $star_index --readFilesCommand zcat --readFilesIn $reads
    """
}

/*
* USE SALMON FOR QUANTIFICATION
*/
process salmon_quant {
    label 'process_medium'
    publishDir "${params.out_dir}/samples/${sampleID}/salmon", mode: params.publish_dir_mode

    input:
    tuple val(sampleID), file(reads) from ch_totalRNA_reads2
    file(salmon_index) from ch_salmon_index

    output:
    val(sampleID) into samples
    file("quant.sf") into quant_files

    script:
    if (params.single_end){
        """
        salmon quant -i $salmon_index -l A -r $reads --validateMappings -o ./
        """
    } else {
        """
        salmon quant -i $salmon_index -l A -1 $reads[0] -2 $reads[1] --validateMappings -o ./
        """
    }
}

/*
* PARSE STAR OUTPUT INTO CIRCExplorer2 FORMAT
*/
process circExplorer2_Parse {
    label 'process_medium'

    publishDir "${params.out_dir}/samples/${sampleID}/circRNA_detection/circExplorer2", mode: params.publish_dir_mode
    
    input:
    tuple val(sampleID), file(chimeric_junction) from chimeric_junction_files

    output:
    tuple val(sampleID), file("back_spliced_junction.bed") into backspliced_junction_bed_files

    script:
    """
    CIRCexplorer2 parse -b "back_spliced_junction.bed" -t STAR $chimeric_junction        
    """
}

/*
* PERFORM circRNA QUANTIFICATION USING CIRCExplorer2
*/
process circExplorer2_Annotate {
    label 'process_medium'

    publishDir "${params.out_dir}/samples/${sampleID}/circRNA_detection/circExplorer2", mode: params.publish_dir_mode
    
    input:
    tuple val(sampleID), file(backspliced_junction_bed) from backspliced_junction_bed_files
    file(fasta) from ch_fasta

    output:
    file("${sampleID}_circularRNA_known.txt") into ch_circRNA_known_files

    script:
    """
    CIRCexplorer2 annotate -r $params.gene_pred -g $fasta -b $backspliced_junction_bed -o "${sampleID}_circularRNA_known.txt"
    """
}

/*
* MERGE RAW circRNA RESULTS INTO ONE TABLE SUMMARIZING ALL SAMPLES
*/
process summarize_detected_circRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_file) from ch_circRNA_known_files.collect()

    output:
    file("circRNA_counts_raw.tsv") into ch_circRNA_counts_raw

    script:
    """
    Rscript "${projectDir}"/bin/circRNA_summarize_results.R $params.samplesheet $params.out_dir
    """
}

/*
* NORMALIZE RAW circRNA COUNT USING LIBRARY SIZE ESTIMATION
*/
process normalize_circRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_counts_raw) from ch_circRNA_counts_raw

    output:
    file("circRNA_counts_normalized.tsv") into (ch_circRNA_counts_norm1, ch_circRNA_counts_norm2)

    script:
    """
    Rscript "${projectDir}"/bin/circRNA_results_LibrarySizeEstimation.R $circRNA_counts_raw $params.out_dir
    """
}

/*
* FILTER circRNAs TO REDUCE LOW EXPRESSED ONES
*/
process filter_circRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_counts_norm) from ch_circRNA_counts_norm1

    output:
    file("circRNA_counts_filtered.tsv") into (ch_circRNA_counts_filtered1, ch_circRNA_counts_filtered2, ch_circRNA_counts_filtered3, ch_circRNA_counts_filtered4, ch_circRNA_counts_filtered5)

    script:
    """
    Rscript "${projectDir}"/bin/circRNA_filtering.R $circRNA_counts_norm $params.out_dir $params.sample_percentage $params.read_threshold $params.species
    """
}

/*
* DATABASE ANNOTATION USING LIFTOVER FOR GENOMIC COORDINATE CONVERSION AND CIRCBASE
*/
if (params.database_annotation){
    process database_annotation{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode

    input:
    file(circRNAs_filtered) from ch_circRNA_counts_filtered1

    output:
    file("circRNA_annotated.tsv") into circRNAs_annotated

    script:
    if( params.offline_circ_db == null )
        """
        python3 "${projectDir}"/bin/circRNA_db_annotation.py -o $params.species -gv $params.genome_version -d $circRNAs_filtered -out "circRNA_annotated.tsv"
        """
    else
        """
        python3 "${projectDir}"/bin/circRNA_db_annotation.py -o $params.species -gv $params.genome_version -d $circRNAs_filtered -out "circRNA_annotated.tsv" -off $params.offline_circ_db
        """
    }
}

/*
* DIFFERENTIAL EXPRESSION ANALYSIS USING SAM FILES FROM STAR
*/
if (params.differential_expression){
    process differential_expression {
        label 'process_medium'
        publishDir "${params.out_dir}/results/differential_expression/", mode: params.publish_dir_mode

        input:
        file(circRNAs_filtered) from ch_circRNA_counts_filtered2
        file(gtf) from ch_gtf
        val(samples_all) from samples.collect()

        output:
        file("gene_expression.tsv") into gene_expression_all
        file("total_rna/total_rna.tsv") into deseq_total_rna
        file("circ_rna/circ_rna.tsv") into deseq_circ_rna
        file("total_rna/*.png") into total_plots
        file("circ_rna/*.png") into circ_plots
        file("DESeq2.RData") into deseq2_rdata

        script:
        """
        Rscript "${projectDir}"/bin/differentialExpression.R "${params.out_dir}/samples/" $params.samplesheet $gtf $circRNAs_filtered
        """
    }
}

/*
* FOR THE PREVIOUSLY DETECTED circRNAs EXTRACT FASTA SEQUENCES
*/
process extract_circRNA_sequences {
    label 'process_medium'
    publishDir "${params.out_dir}/results/binding_sites/input/", mode: params.publish_dir_mode
    
    input:
    file(circRNAs_filtered) from ch_circRNA_counts_filtered3
    file(fasta) from ch_fasta

    output:
    file("circRNAs.fa") into circRNAs_fasta

    script:
    """
	bash "${projectDir}"/bin/get_circRNA_sequences.sh $fasta $circRNAs_filtered "circRNAs.fa"
    """
}

/*
* DETERMINE miRNA BINDING SITES ON THE PREVIOUSLY DETECTED circRNAs USING miranda
*/
process miranda {
    label 'process_long'
    publishDir "${params.out_dir}/results/binding_sites/output/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_fasta) from circRNAs_fasta

    output:
    file("bind_sites_raw.out") into bind_sites_out

    script:
    """
    miranda $params.mature_fasta $circRNA_fasta -out "bind_sites_raw.out" -quiet
    """
}

/*
* PROCESS miranda OUTPUT INTO A TABLE FORMAT
*/
process binding_sites_processing {
    label 'process_medium'
    publishDir "${params.out_dir}/results/binding_sites/output/", mode: params.publish_dir_mode
    
    input:
    file(bind_sites_raw) from bind_sites_out

    output:
    file("bind_sites_processed.txt") into bind_sites_processed

    script:
    """
    echo -e "miRNA\tTarget\tScore\tEnergy-Kcal/Mol\tQuery-Al(Start-End)\tSubject-Al(Start-End)\tAl-Len\tSubject-Identity\tQuery-Identity" > "bind_sites_processed.txt"
    grep -A 1 "Scores for this hit:" $bind_sites_raw | sort | grep ">" | cut -c 2- >> "bind_sites_processed.txt"
    """
}

/*
* FILTER BINDING SITES, KEEP TOP 25%
*/
process binding_sites_filtering {
    label 'process_medium'
    publishDir "${params.out_dir}/results/binding_sites/output/", mode: params.publish_dir_mode
    
    input:
    file(bind_sites_proc) from bind_sites_processed
    
    output:
    file("bindsites_25%_filtered.tsv") into (ch_bindsites_filtered1, ch_bindsites_filtered2)

    script:
    """
    Rscript "${projectDir}"/bin/binding_sites_analysis.R ${bind_sites_proc}
    """

}

/*
 * RUN miRNA part only if circRNA_only==false
 */

if (!params.circRNA_only) {
/*
 * GET miRNA RAW COUNTS
 */
if( params.miRNA_raw_counts != null ) {

    /*
     * IF RAW miRNA COUNTS ARE ALREADY SPECIFIED IN A FILE
     */
    ch_miRNA_counts_raw = Channel.fromPath(params.miRNA_raw_counts) 

} else {
   
    /*
     * PERFORM miRNA DETECTION USING miRDeep2 FROM SPECIFIED READ FILES
     * CREATE INPUT CHANNEL
     */

ch_smallRNA_reads=Channel.fromPath(params.samplesheet)
   .splitCsv( header:true, sep:'\t')
   .map { get_miRNA_paths(it) }

/*
* GENERATE BOWTIE INDEX IN CASE IT IS NOT ALREADY PROVIDED
*/
process generate_bowtie_index{
    label 'process_high'
    publishDir "${params.out_dir}/bowtie_index/", mode: params.publish_dir_mode

    input:
    file(fasta) from ch_fasta
    
    output:
    file("${fasta.baseName}*") into ch_generated_bowtie_index
                      
    when: (params.bowtie_index == null)

    script:
    """
    echo "bowtie index is in ${fasta.baseName}"
    bowtie-build $fasta ${fasta.baseName}
    """
}

ch_bowtie_index = params.bowtie_index ? Channel.value(file(params.bowtie_index)) : ch_generated_bowtie_index



    /*
     * PERFORM miRNA READ MAPPING USING miRDeep2
     */
    process miRDeep2_mapping {
        label 'process_high'
        publishDir "${params.out_dir}/samples/${sampleID}/miRNA_detection/", mode: params.publish_dir_mode

        input:
        tuple val(sampleID), file(read_file) from ch_smallRNA_reads
        file(index) from ch_bowtie_index.collect()
        file(fasta) from ch_fasta

        output: 
        tuple val(sampleID), file("reads_collapsed.fa"), file("reads_vs_ref.arf") into ch_miRNA_mapping_output

        script:
        """
	    gunzip < $read_file > "${sampleID}.fastq"
        mapper.pl "${sampleID}.fastq" -e -h -i -j -k $params.miRNA_adapter -l 18 -m -p ${fasta.baseName} -s "reads_collapsed.fa" -t "reads_vs_ref.arf" -v
        """
    }

    /*
     * PERFORM miRNA QUANTIFICATION USING miRDeep2
     */
    process miRDeep2_quantification {
        label 'process_high'
        publishDir "${params.out_dir}/samples/${sampleID}/miRNA_detection/", mode: params.publish_dir_mode
 
        input:
        tuple val(sampleID), file(reads_collapsed_fa), file(reads_vs_ref_arf) from ch_miRNA_mapping_output
    	file(fasta) from ch_fasta

        output:
        file("miRNAs_expressed*") into ch_miRNA_expression_files

        script:
        """
        miRDeep2.pl $reads_collapsed_fa $fasta $reads_vs_ref_arf $params.mature_fasta $params.mature_other_fasta $params.hairpin_fasta -t $params.species -d -v 
        """
    }

    /*
     * MERGE RAW miRNA RESULTS INTO ONE TABLE SUMMARIZING ALL SAMPLES
     */
    process summarize_detected_miRNAs{
        label 'process_medium'

        publishDir "${params.out_dir}/results/miRNA/", mode: params.publish_dir_mode
    
        input:
        file(miRNAs_expressed) from ch_miRNA_expression_files.collect()

        output:
        file("miRNA_counts_raw.tsv") into ch_miRNA_counts_raw

        script:
        """
        Rscript "${projectDir}"/bin/miRNA_summarize_results.R $params.samplesheet $params.out_dir
        """
    }

}

/*
* NORMALIZE RAW miRNA COUNT USING LIBRARY SIZE ESTIMATION
*/
process normalize_miRNAs{
    label 'process_low'

    publishDir "${params.out_dir}/results/miRNA/", mode: params.publish_dir_mode
    
    input:
    file(miRNA_counts_raw) from ch_miRNA_counts_raw

    output:
    file("miRNA_counts_normalized.tsv") into (ch_miRNA_counts_norm1, ch_miRNA_counts_norm2)

    script:
    """
    Rscript "${projectDir}"/bin/miRNA_results_LibrarySizeEstimation.R $miRNA_counts_raw $params.out_dir
    """
}

/*
* FILTER miRNAs TO REDUCE LOW EXPRESSED ONES
*/
process filter_miRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/miRNA/", mode: params.publish_dir_mode
    
    input:
    file(miRNA_counts_norm) from ch_miRNA_counts_norm1

    output:
    file("miRNA_counts_filtered.tsv") into (ch_miRNA_counts_filtered1, ch_miRNA_counts_filtered2, ch_miRNA_counts_filtered3, ch_miRNA_counts_filtered4)

    script:
    """
    Rscript "${projectDir}"/bin/miRNA_filtering.R $miRNA_counts_norm $params.out_dir $params.sample_percentage $params.read_threshold
    """
}


/*
* FOR ALL POSSIBLE circRNA-miRNA PAIRS COMPUTE PEARSON CORRELATION
*/
process compute_correlations{
    label 'process_medium'

    publishDir "${params.out_dir}/results/sponging/", mode: params.publish_dir_mode
    
    input:
    file(miRNA_counts_filtered) from ch_miRNA_counts_filtered1
    file(circRNA_counts_filtered) from ch_circRNA_counts_filtered4
    file(filtered_bindsites) from ch_bindsites_filtered1

    output:
    file("filtered_circRNA_miRNA_correlation.tsv") into ch_correlations

    script:
    """
    Rscript "${projectDir}"/bin/compute_correlations.R $params.samplesheet $miRNA_counts_filtered $circRNA_counts_filtered $filtered_bindsites
    """
}

/*
* ANALYZE THE CORRELATION OF ALL PAIRS AND DETERMINE OVERALL DISTRIBUTION
* USING BINDING SITES INFORMATION. COMPUTE STATISTICS AND PLOTS
*/
process correlation_analysis{
    label 'process_high'

    publishDir "${params.out_dir}/results/sponging/", mode: params.publish_dir_mode
    
    input:
    file(correlations) from ch_correlations
    file(miRNA_counts_filtered) from ch_miRNA_counts_filtered2
    file(circRNA_counts_filtered) from ch_circRNA_counts_filtered5
    file(miRNA_counts_norm) from ch_miRNA_counts_norm2
    file(circRNA_counts_norm) from ch_circRNA_counts_norm2


    output:
    file("sponging_statistics.txt") into ch_sponging_statistics
    file("plots/*.png") into ch_plots

    script:
    """
    mkdir -p "${params.out_dir}/results/sponging/plots/"
    Rscript "${projectDir}"/bin/correlation_analysis.R $params.samplesheet $miRNA_counts_filtered $circRNA_counts_filtered $correlations $params.out_dir $params.sample_group $miRNA_counts_norm $circRNA_counts_norm
    """
}

/*
* SPONGE ANALYSIS (https://github.com/biomedbigdata/SPONGE)
*/
if (params.database_annotation) {
    process SPONGE_db_annotation{
        label 'process_high'

        publishDir "${params.out_dir}/results/SPONGE", mode: params.publish_dir_mode

        input:
        file(gene_expression) from gene_expression_all
        file(circRNA_annotated) from circRNA_annotated
        file(mirna_expression) from ch_miRNA_counts_filtered4
        file(miranda_bind_sites) from ch_bindsites_filtered2

        output:
        file("sponge.RData") into Rimage
        file("plots/*.png") into ch_sponge_plots

        script:
        """
        Rscript "${projectDir}"/bin/SPONGE.R \\
        --gene_expr $gene_expression \\
        --circ_annotated $circRNA_annotated \\
        --mirna_expr $mirna_expression \\
        --organism $params.organism \\
        --fdr $params.fdr \\
        --target_scan_symbols $params.target_scan_symbols \\
        --miRTarBase_loc $params.miRTarBaseData \\
        --miranda_data $miranda_bind_sites \\
        --TargetScan_data $params.TargetScanData \\
        --lncBase_data $params.lncBaseData
        """
    }
} else {
    process SPONGE{
        label 'process_high'

        publishDir "${params.out_dir}/results/SPONGE", mode: params.publish_dir_mode

        input:
        file(gene_expression) from gene_expression_all
        file(mirna_expression) from ch_miRNA_counts_filtered4
        file(miranda_bind_sites) from ch_bindsites_filtered2

        output:
        file("sponge.RData") into Rimage
        file("plots/*.png") into ch_sponge_plots

        script:
        """
        Rscript "${projectDir}"/bin/SPONGE.R \\
        --gene_expr $gene_expression \\
        --mirna_expr $mirna_expression \\
        --organism $params.organism \\
        --fdr $params.fdr \\
        --target_scan_symbols $params.target_scan_symbols \\
        --miRTarBase_loc $params.miRTarBaseData \\
        --miranda_data $miranda_bind_sites \\
        --TargetScan_data $params.TargetScanData \\
        --lncBase_data $params.lncBaseData
        """
    }
}
}
