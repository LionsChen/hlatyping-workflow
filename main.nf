#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/hlatyping
========================================================================================
 nf-core/hlatyping Analysis Pipeline. Started 2018-06-01.
 #### Homepage / Documentation
 https://github.com/nf-core/hlatyping
 #### Authors
 Sven Fillinger sven1103 <sven.fillinger@qbic.uni-tuebingen.de> - https://github.com/sven1103>
 Christopher Mohr christopher-mohr <christopher.mohr@uni-tuebingen.de>
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info"""
    =========================================
     nf-core/hlatyping v${params.version}
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/hlatyping --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      --rna/--dna                   Use with RNA/DNA sequencing data.
      --outdir OUTDIR               The output directory where the results will be saved
      -profile                      Hardware config to use. docker / aws

    Options:
      --bam                         If the input format is of type BAM. A remapping step with yara mapper against the HLA
                                    reference is performed in this case
      --singleEnd                   Specifies that the input is single end reads
      --beta B                      The beta value for for homozygosity detection (see paper). Default: 0.009. Handle with care.
      --enumerate N                 Number of enumerations. OptiType will output the optimal solution and the top N-1 suboptimal solutions
                                    in the results CSV. Default: 1
      --solver SOLVER               Choose between different IP solver (glpk, cbc). Default: glpk

    Other options:
      --prefix PREFIX               Specifies a prefix of output files from Optitype
      --verbose                     Activate verbose mode of Optitype
      --email EMAIL                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name NAME                    Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.name = false
params.multiqc_config = "$baseDir/conf/multiqc_config.yaml"
params.email = false
params.plaintext_email = false

output_docs = file("$baseDir/docs/output.md")

// Validate inputs
params.reads ?: params.readPaths ?: { log.error "No read data privided. Make sure you have used the '--reads' option."; exit 1 }()
params.seqtype ?: { log.error "No sequence type provided, you need to add '--dna/--rna.'"; exit 1 }()
if( params.bam ) params.index ?: { log.error "For BAM option, you need to provide a path to the HLA reference index (yara; --index) "; exit 1 }()
params.outdir = params.outdir ?: { log.warn "No output directory provided. Will put the results into './results'"; return "./results" }()

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}



// Header log info
log.info "========================================="
log.info " nf-core/hlatyping v${params.version}"
log.info "========================================="
def summary = [:]
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.readPaths? params.readPaths : params.reads
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['File Type']    = params.bam ? 'BAM' : 'Other (fastq, fastq.gz, ...)'
summary['IP solver']    = params.solver
summary['Enumerations'] = params.enumerations
summary['Beta'] = params.beta
summary['Prefix'] = params.prefix
summary['Max Memory']   = params.max_memory
summary['Max CP Us']     = params.max_cpus
summary['Max Time']     = params.max_time
summary['Output dir']   = params.outdir
summary['Working dir']  = workflow.workDir
summary['Container']    = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
try {
    if( ! nextflow.version.matches(">= $params.nf_required_version") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $params.nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}


if( params.readPaths ){
    if( params.singleEnd || params.bam) {
        Channel
            .from( params.readPaths )
            .map { row -> [ row[0], [ file( row[1][0] ) ] ] }
            .ifEmpty { exit 1, "params.readPaths or params.bams was empty - no input files supplied!" }
            .set { input_data }
    } else {
        Channel
            .from( params.readPaths )
            .map { row -> [ row[0], [ file( row[1][0] ), file( row[1][1] ) ] ] }
            .ifEmpty { exit 1, "params.readPaths or params.bams was empty - no input files supplied!" }
            .set { input_data }
    }
} else {
     Channel
        .fromFilePairs( params.reads, size: params.singleEnd || params.bam ? 1 : 2 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs" +
            "to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
        .set { input_data }
}


if( params.bam ) log.info "BAM file format detected. Initiate remapping to HLA alleles with yara mapper."

/*
 * Preparation - Unpack files if packed.
 * 
 * OptiType cannot handle *.gz archives as input files, 
 * So we have to unpack first, if this is the case. 
 */
if ( !params.bam  ) { // FASTQ files processing
    process unzip {

            input:
            set val(pattern), file(reads) from input_data

            output:
            set val(pattern), "unzipped_{1,2}.fastq" into raw_reads

            script:
            if(params.singleEnd == true)
            """
            zcat ${reads[0]} > unzipped_1.fastq
            """
            else
            """
            zcat ${reads[0]} > unzipped_1.fastq
            zcat ${reads[1]} > unzipped_2.fastq
            """
    }
} else { // BAM files processing

    /*
     * Preparation - Remapping of reads against HLA reference and filtering these
     *
     * In case the user provides BAM files, a remapping step
     * is then done against the HLA reference sequence.
     */
    process remap_to_hla {
        
        input:
        set val(pattern), file(bams) from input_data

        output:
        set val(pattern), "mapped_{1,2}.bam" into fished_reads

        script:
        if (params.singleEnd)
        """
        samtools bam2fq $bams > output_1.fastq
        yara_mapper -e 3 -t ${params.max_cpus} -f bam ${workflow.projectDir}/${params.index} output_1.fastq > output_1.bam
        samtools view -h -F 4 -b1 output_1.bam > mapped_1.bam
        """
        else
        """
        samtools view -h -f 0x40 $bams > output_1.bam
        samtools view -h -f 0x80 $bams > output_2.bam
        samtools bam2fq output_1.bam > output_1.fastq
        samtools bam2fq output_2.bam > output_2.fastq
        yara_mapper -e 3 -t ${params.max_cpus} -f bam ${workflow.projectDir}/${params.index} output_1.fastq output_2.fastq > output.bam
        samtools view -h -F 4 -f 0x40 -b1 output.bam > mapped_1.bam
        samtools view -h -F 4 -f 0x80 -b1 output.bam > mapped_2.bam
        """

    }

}
 

/*
 * STEP 1 - Create config.ini for Optitype
 *
 * Optitype requires a config.ini file with information like
 * which solver to use for the optimization step. Also, the number
 * of threads is specified there for different steps.
 * As we do not want to touch the original source code of Optitype,
 * we simply take information from Nextflow about the available resources
 * and create a small config.ini as first stepm which is then passed to Optitype.
 */
process make_ot_config {

    publishDir "${params.outdir}/config", mode: 'copy'

    output:
    file 'config.ini' into config

    script:
    """
    configbuilder --max-cpus ${params.max_cpus} --solver ${params.solver} > config.ini
    """

}

/*
 * Preparation Step - Pre-mapping against HLA
 * 
 * In order to avoid the internal usage of RazerS from within OptiType when 
 * the input files are of type `fastq`, we perform a pre-mapping step
 * here with the `yara` mapper, and map against the HLA reference only. 
 *
 */
if (!params.bam)
process pre_map_hla {
    
    input:
    set val(pattern), file(reads) from raw_reads

    output:
    set val(pattern), "mapped_{1,2}.bam" into fished_reads

    script:
    if (params.singleEnd)
    """
    yara_mapper -e 3 -t ${params.max_cpus} -f bam ${workflow.projectDir}/${params.index} $reads > output_1.bam
    samtools view -h -F 4 -b1 output_1.bam > mapped_1.bam
    """
    else
    """
    yara_mapper -e 3 -t ${params.max_cpus} -f bam ${workflow.projectDir}/${params.index} $reads > output.bam
    samtools view -h -F 4 -f 0x40 -b1 output.bam > mapped_1.bam
    samtools view -h -F 4 -f 0x80 -b1 output.bam > mapped_2.bam
    """

}

/*
 * STEP 2 - Run Optitype
 * 
 * This is the major process, that formulates the IP and calls the selected
 * IP solver.
 *  
 * Ouput formats: <still to enter>
 */
process run_optitype {

    publishDir "${params.outdir}/optitype", mode: 'copy', pattern: 'results/*'

    input:
    file 'config.ini' from config
    set val(x), file(reads) from fished_reads

    script:
    """
    OptiTypePipeline.py -i ${reads} -e ${params.enumerations} -b ${params.beta} -p "${params.prefix}" -c config.ini --${params.seqtype} --outdir ${params.outdir}
    """
}


/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/hlatyping] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/hlatyping] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = params.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['software_versions'] = software_versions
    //email_fields['software_versions']['Nextflow Build'] = workflow.nextflow.build
    //email_fields['software_versions']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir" ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/hlatyping] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/hlatyping] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/Documentation/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    log.info "[nf-core/hlatyping] Pipeline Complete"

}
