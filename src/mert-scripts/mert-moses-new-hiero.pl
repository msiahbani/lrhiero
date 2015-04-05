#!/usr/bin/perl -w 

# $Id: mert-moses.pl 1745 2008-05-16 15:54:02Z phkoehn $
# Usage:
# mert-moses.pl <foreign> <english> <decoder-executable> <decoder-config>
# For other options see below or run 'mert-moses.pl --help'

# Notes:
# <foreign> and <english> should be raw text files, one sentence per line
# <english> can be a prefix, in which case the files are <english>0, <english>1, etc. are used

# Revision history

# March 2015    Modified by Maryam Siahbani for use lrhiero decoder (adding lexicalized reordering model files)
# Apr 2009    Modified by Baskaran Sankaran for use with home-grown (SFU) Hierarchical MT decoder
# 5 Jun 2008  Forked previous version to support new mert implementation.
# 13 Feb 2007 Better handling of default values for lambda, now works with multiple
#             models and lexicalized reordering
# 11 Oct 2006 Handle different input types through parameter --inputype=[0|1]
#             (0 for text, 1 for confusion network, default is 0) (Nicola Bertoldi)
# 10 Oct 2006 Allow skip of filtering of phrase tables (--no-filter-phrase-table)
#             useful if binary phrase tables are used (Nicola Bertoldi)
# 28 Aug 2006 Use either closest or average or shortest (default) reference
#             length as effective reference length
#             Use either normalization or not (default) of texts (Nicola Bertoldi)
# 31 Jul 2006 move gzip run*.out to avoid failure wit restartings
#             adding default paths
# 29 Jul 2006 run-filter, score-nbest and mert run on the queue (Nicola; Ondrej had to type it in again)
# 28 Jul 2006 attempt at foolproof usage, strong checking of input validity, merged the parallel and nonparallel version (Ondrej Bojar)
# 27 Jul 2006 adding the safesystem() function to handle with process failure
# 22 Jul 2006 fixed a bug about handling relative path of configuration file (Nicola Bertoldi) 
# 21 Jul 2006 adapted for Moses-in-parallel (Nicola Bertoldi) 
# 18 Jul 2006 adapted for Moses and cleaned up (PK)
# 21 Jan 2005 unified various versions, thorough cleanup (DWC)
#             now indexing accumulated n-best list solely by feature vectors
# 14 Dec 2004 reimplemented find_threshold_points in C (NMD)
# 25 Oct 2004 Use either average or shortest (default) reference
#             length as effective reference length (DWC)
# 13 Oct 2004 Use alternative decoders (DWC)
# Original version by Philipp Koehn

use FindBin qw($Bin);
use File::Basename;
my $SCRIPTS_ROOTDIR = $Bin;
$SCRIPTS_ROOTDIR =~ s/\/mert\-scripts$//;
$SCRIPTS_ROOTDIR = $ENV{"SCRIPTS_ROOTDIR"} if defined($ENV{"SCRIPTS_ROOTDIR"});

# for each _d_istortion, _l_anguage _m_odel, _t_ranslation _m_odel and _w_ord penalty, there is a list
# of [ default value, lower bound, upper bound ]-triples. In most cases, only one triple is used,
# but the translation model has currently 5 features

# defaults for initial values and ranges are:
my $default_triples = {
    # this basic model exist even if not specified, they are
    # not associated with any model file
    "wp" => [ [-1.0,-2.0, 0.0] ],     # word penalty
    "glue" => [ [ 1.0, 0.0, 2.0 ] ],  # glue rules
    "d" => [ [ 1.0, -1.0, 2.0 ] ],  # distortion
    "dg" => [ [ 1.0, -1.0, 2.0 ] ],  # glue distortion
    "wd" => [ [ 1.0, -1.0, 2.0 ] ],  # width
    "hd" => [ [ 1.0, -1.0, 2.0 ] ],  # height
    "r" => [ [ 1.0, -1.0, 2.0 ] ],  # rule reordering
};

my $additional_triples = {
    # if the more lambda parameters for the weights are needed
    # (due to additional tables) use the following values for them
    "tm" => [ [ 0.8, 0.0, 1.0 ],      # translation model
              [ 0.9, 0.0, 1.0 ],
              [ 0.6, 0.0, 1.0 ],
              [ 0.4, 0.0, 1.0 ],
              [ 1.0,-1.0, 2.0 ] ],    # phrase penalty
    "lm" => [ [ 1.0, 0.0, 2.0 ] ],    # language model
    "rm" => [ [ 0.6, 0.0, 1.0 ],      # reordering model
              [ 0.6, 0.0, 1.0 ],
              [ 0.6, 0.0, 1.0 ],
              [ 0.6, 0.0, 1.0 ],
              [ 0.6, 0.0, 1.0 ],
              [ 0.6, 0.0, 1.0 ] ],    
};

# moses.ini file uses FULL names for lambdas, while this training script internally (and on the command line)
# uses ABBR names.
my $ABBR_FULL_MAP = "lm=weight_lm tm=weight_tm wp=weight_wp glue=weight_glue d=weight_d dg=weight_dg wd=weight_wd hd=weight_hd r=weight_r rm=weight_rm";
my %ABBR2FULL = map {split/=/,$_,2} split /\s+/, $ABBR_FULL_MAP;
my %FULL2ABBR = map {my ($a, $b) = split/=/,$_,2; ($b, $a);} split /\s+/, $ABBR_FULL_MAP;

# We parse moses.ini to figure out how many weights do we need to optimize.
# For this, we must know the correspondence between options defining files
# for models and options assigning weights to these models.
#my $TABLECONFIG_ABBR_MAP = "ttable-file=tm lmodel-file=lm distortion-file=d generation-file=g";
my $TABLECONFIG_ABBR_MAP = "ttable-file=tm lmodel-file=lm";
my %TABLECONFIG2ABBR = map {split(/=/,$_,2)} split /\s+/, $TABLECONFIG_ABBR_MAP;

# There are weights that do not correspond to any input file, they just increase the total number of lambdas we optimize
#my $extra_lambdas_for_model = {
#  "glue" => 1,  # glue rule weight
#};

my $minimum_required_change_in_weights = 0.00001;
    # stop if no lambda changes more than this

my $verbose = 0;
my $usage = 0; # request for --help
my $___WORKING_DIR = "mert-work";
my $___DEV_F = undef; # required, input text to decode
my $___DEV_E = undef; # required, basename of files with references
my $___GLUE_RULES = undef; # required, file having Glue rules
my $___SCFG_RULES = undef; # required, basename of the directory having the SCFG rule files
my $___RM_RULES = undef; # optional, basename of the directory having the reordering model files
my $___DECODER = undef; # required, pathname to the decoder executable
my $___CONFIG = undef; # required, pathname to startup ini file
my $___LM_FILE = undef; # required, LM file (w/ absolute path)
my $___N_BEST_LIST_SIZE = 100;
my $queue_flags = "-l mem=5gb -l walltime=01:30:00";  # extra parameters for parallelizer
      # the -l ws0ssmt is relevant only to JHU workshop
my $___JOBS = undef; # if parallel, number of jobs to use (undef -> serial)
my $___DECODER_PREFIX = ""; # prefix for the decoder
my $___DECODER_FLAGS = ""; # additional parametrs to pass to the decoder (only feature weight related flags)
my $kriya_opts = ""; # parameters for the kriya decoder (non-feature weight options that are directly passed to Kriya)
my $nodes_prop = ""; # specifies the feature name describing the nodes
my $___LAMBDA = undef; # string specifying the seed weights and boundaries of all lambdas
my $continue = 0; # should we try to continue from the last saved step?
my $skip_decoder = 0; # and should we skip the first decoder run (assuming we got interrupted during mert)
my $___FILTER_PHRASE_TABLE = 0; # filter phrase table; changed to '0' (from '1') by Baskaran Sankaran


# set 1 if using with async decoder
my $___ASYNC = 0; 

# Parameter for effective reference length when computing BLEU score
# This is used by score-nbest-bleu.py
# Default is to use shortest reference
# Use "--average" to use average reference length
# Use "--closest" to use closest reference length
# Only one between --average and --closest can be set
# If both --average is used
#TODO: Pass these through to scorer
my $___AVERAGE = 0;
my $___CLOSEST = 0;

# Use "--nonorm" to non normalize translation before computing BLEU
my $___NONORM = 0;

# set 0 if input type is text, set 1 if input type is confusion network
my $___INPUTTYPE = 0; 

my $allow_unknown_lambdas = 0;
my $allow_skipping_lambdas = 0;

my $mertdir = undef; # path to new mert directory
my $mertargs = undef; # args to pass through to mert
my $mert_status = 100; # 3 digit code to indicate the status of mert
my $prev_jobid = 0; # id of the previous job aborted (to continue from halfway), default 0
my $pythonpath = undef; # path to python libraries needed by cmert
my $filtercmd = undef; # path to filter-model-given-input.pl
my $SCORENBESTCMD = undef;
my $qsubwrapper = undef;
my $moses_parallel_cmd = undef;
my $old_sge = 0; # assume sge<6.0
my $___CONFIG_BAK = undef; # backup pathname to startup ini file
my $obo_scorenbest = undef; # set to pathname to a Ondrej Bojar's scorer (not included
                            # in scripts distribution)
my $efficient_scorenbest_flag = undef; # set to 1 to activate a time-efficient scoring of nbest lists
                                  # (this method is more memory-consumptive)
my $___ACTIVATE_FEATURES = undef; # comma-separated (or blank-separated) list of features to work on 
                                  # if undef work on all features
                                  # (others are fixed to the starting values)

use strict;
use Getopt::Long;
GetOptions(
  "working-dir=s" => \$___WORKING_DIR,
  "input=s" => \$___DEV_F,
  "gluefile=s" => \$___GLUE_RULES,
  "scfgpath=s" => \$___SCFG_RULES,
  "rmpath=s" => \$___RM_RULES,
  "inputtype=i" => \$___INPUTTYPE,
  "refs=s" => \$___DEV_E,
  "decoder=s" => \$___DECODER,
  "config=s" => \$___CONFIG,
  "lmfile=s" => \$___LM_FILE,
  "nbest=i" => \$___N_BEST_LIST_SIZE,
  "queue-flags=s" => \$queue_flags,
  "nodes-prop=s" => \$nodes_prop,
  "jobs=i" => \$___JOBS,
  "decoder-prefix=s" => \$___DECODER_PREFIX,
  "decoder-flags=s" => \$___DECODER_FLAGS,
  "kriya-opts=s" => \$kriya_opts,
  "lambdas=s" => \$___LAMBDA,
  "continue" => \$continue,
  "skip-decoder" => \$skip_decoder,
  "average" => \$___AVERAGE,
  "closest" => \$___CLOSEST,
  "nonorm" => \$___NONORM,
  "help" => \$usage,
  "allow-unknown-lambdas" => \$allow_unknown_lambdas,
  "allow-skipping-lambdas" => \$allow_skipping_lambdas,
  "verbose" => \$verbose,
  "mertdir=s" => \$mertdir,
  "mertargs=s" => \$mertargs,
  "mertstatus=i" => \$mert_status,
  "prevjobid=i" => \$prev_jobid,
  "rootdir=s" => \$SCRIPTS_ROOTDIR,
  "pythonpath=s" => \$pythonpath,
  "filtercmd=s" => \$filtercmd, # allow to override the default location
  "scorenbestcmd=s" => \$SCORENBESTCMD, # path to score-nbest.py
  "qsubwrapper=s" => \$qsubwrapper, # allow to override the default location
  "mosesparallelcmd=s" => \$moses_parallel_cmd, # allow to override the default location
  "old-sge" => \$old_sge, #passed to moses-parallel
  "filter-phrase-table!" => \$___FILTER_PHRASE_TABLE, # allow (disallow)filtering of phrase tables
  "obo-scorenbest=s" => \$obo_scorenbest, # see above
  "efficient_scorenbest_flag" => \$efficient_scorenbest_flag, # activate a time-efficient scoring of nbest lists
  "async=i" => \$___ASYNC, #whether script to be used with async decoder
  "activate-features=s" => \$___ACTIVATE_FEATURES, #comma-separated (or blank-separated) list of features to work on (others are fixed to the starting values)
) or exit(1);

# the 4 required parameters can be supplied on the command line directly
# or using the --options
if (scalar @ARGV == 4) {
  # required parameters: input_file references_basename decoder_executable
  $___DEV_F = shift;
  $___DEV_E = shift;
  $___DECODER = shift;
  $___CONFIG = shift;
}

if ($___ASYNC) {
    delete $default_triples->{"w"};
    $additional_triples->{"w"} = [ [ 0.0, -1.0, 1.0 ] ];
}

$queue_flags =~ s/__/ /;
print STDERR "After default: $queue_flags\n";

if ($usage || !defined $___DEV_F || !defined $___DEV_E || !defined $___DECODER || !defined $___CONFIG) {
  print STDERR "usage: mert-moses-new.pl input-text references decoder-executable decoder.ini
Options:
  --working-dir=mert-dir ... where all the files are created
  --gluefile=STRING ... file having the Glue rules
  --scfgpath=STRING ... path to the SCFG rule files corresponding to the input sentences files
  --lmfile=STRING ... LM file (w/ absolute path)
  --nbest=100 ... how big nbestlist to generate
  --jobs=N  ... set this to anything to run moses in parallel
  --mosesparallelcmd=STRING ... use a different script instead of moses-parallel
  --queue-flags=STRING  ... anything you with to pass to 
              qsub, eg. '-l ws06osssmt=true'
              The default is 
								-l mem=5gb,walltime=00:50:00
              To reset the parameters, please use \"--queue-flags=' '\" (i.e. a space between
              the quotes).
  --nodes-prop=STRING ... specifies the feature name describing the nodes
  --decoder-prefix=STRING ... prefix for the decoder (such as interpreter to be used)
  --decoder-flags=STRING ... extra parameters for the decoder
  --lambdas=STRING  ... default values and ranges for lambdas, a complex string
         such as 'd:1,0.5-1.5 lm:1,0.5-1.5 tm:0.3,0.25-0.75;0.2,0.25-0.75;0.2,0.25-0.75;0.3,0.25-0.75;0,-0.5-0.5 w:0,-0.5-0.5'
  --allow-unknown-lambdas ... keep going even if someone supplies a new lambda
         in the lambdas option (such as 'superbmodel:1,0-1'); optimize it, too
  --continue  ... continue from the last achieved state
  --skip-decoder ... skip the decoder run for the first time, assuming that
                     we got interrupted during optimization
  --average ... Use either average or shortest (default) reference
                  length as effective reference length
  --closest ... Use either closest or shortest (default) reference
                  length as effective reference length
  --nonorm ... Do not use text normalization
  --filtercmd=STRING  ... path to filter-model-given-input.pl
  --rootdir=STRING  ... where do helpers reside (if not given explicitly)
  --mertdir=STRING ... path to new mert implementation
  --mertargs=STRING ... extra args for mert, eg to specify scorer
  --mertstatus=INT ... 3 digit code for the status of MERT
  --prevjobid=INT ... id of the job to be continued from previous abortion
  --pythonpath=STRING  ... where is python executable
  --scorenbestcmd=STRING  ... path to score-nbest.py
  --old-sge ... passed to moses-parallel, assume Sun Grid Engine < 6.0
  --inputtype=[0|1|2] ... Handle different input types (0 for text, 1 for confusion network, 2 for lattices, default is 0)
  --no-filter-phrase-table ... disallow filtering of phrase tables
                              (useful if binary phrase tables are available)
  --efficient_scorenbest_flag ... activate a time-efficient scoring of nbest lists
                                  (this method is more memory-consumptive)
  --activate-features=STRING  ... comma-separated list of features to work on
                                  (if undef work on all features)
                                  # (others are fixed to the starting values)
";
  exit 1;
}

# Check validity of input parameters and set defaults if needed

print STDERR "Using SCRIPTS_ROOTDIR: $SCRIPTS_ROOTDIR\n";

# path of script for filtering phrase tables and running the decoder
$filtercmd="$SCRIPTS_ROOTDIR/pre-process/filterRules4Dataset.pl" if !defined $filtercmd;
$qsubwrapper="$SCRIPTS_ROOTDIR/mert-scripts/qsub-wrapper.pl" if !defined $qsubwrapper;
$moses_parallel_cmd = "$SCRIPTS_ROOTDIR/mert-scripts/hiero-parallel.pl"
  if !defined $moses_parallel_cmd;

die "Error: need to specify the mert directory" if !defined $mertdir;

my $mert_extract_cmd = "$mertdir/extractor";
my $mert_mert_cmd = "$mertdir/mert";

die "Not executable: $mert_extract_cmd" if ! -x $mert_extract_cmd;
die "Not executable: $mert_mert_cmd" if ! -x $mert_mert_cmd;

if (defined $mertargs) { $mertargs =~ s/\=/ /; }
$mertargs = "" if !defined $mertargs;

my ($just_cmd_filtercmd,$x) = split(/ /,$filtercmd);
die "Not executable: $just_cmd_filtercmd" if ! -x $just_cmd_filtercmd;
die "Not executable: $moses_parallel_cmd" if defined $___JOBS && ! -x $moses_parallel_cmd;
die "Not executable: $qsubwrapper" if defined $___JOBS && ! -x $qsubwrapper;
die "Not executable: $___DECODER" if ! -x $___DECODER;

if (defined $obo_scorenbest) {
  die "Not executable: $obo_scorenbest" if ! -x $___DECODER;
  die "Ondrej's scorenbest supports only closest ref length"
    if $___AVERAGE;
}


my $input_abs = ensure_full_path($___DEV_F);
die "Directory not found: $___DEV_F (interpreted as $input_abs)."
  if ! -e $input_abs;
$___DEV_F = $input_abs;


# Option to pass to qsubwrapper and moses-parallel
my $pass_old_sge = $old_sge ? "-old-sge" : "";

my $decoder_abs = ensure_full_path($___DECODER);
die "File not found: $___DECODER (interpreted as $decoder_abs)."
  if ! -x $decoder_abs;
$___DECODER = $decoder_abs;

my $ref_abs = ensure_full_path($___DEV_E);
# check if English dev set (reference translations) exist and store a list of all references
my @references;  
if (-e $ref_abs) {
    push @references, $ref_abs;
}
else {
    # if multiple file, get a full list of the files
    my $part = 0;
    while (-e $ref_abs.$part) {
        push @references, $ref_abs.$part;
        $part++;
    }
    die("Reference translations not found: $___DEV_E (interpreted as $ref_abs)") unless $part;
}
# check if English dev set (reference translations) exist
#die("Reference translations not found: $___DEV_E\n") unless(-e $___DEV_E);

# check if SCFG rules exist
my $scfg_abs = ensure_full_path($___SCFG_RULES);
die "Directory not found: $___SCFG_RULES (interpreted as $scfg_abs)."
  if ! -e $scfg_abs;
$___SCFG_RULES = $scfg_abs;

# check if RM files exist
if (defined $___RM_RULES) {
    my $rm_abs = ensure_full_path($___RM_RULES);
    die "Directory not found: $___RM_RULES (interpreted as $rm_abs)."
      if ! -e $rm_abs;
    $___RM_RULES = $rm_abs;
}


# set start run
my $start_run = 1;
my $run;
if ($mert_status != 100) {
    $mert_status =~ s/^(\d+)?(\d\d)$/$run=$1;$1.$2/ex;
    $___CONFIG = $___WORKING_DIR."/run$run.moses.ini";
    $run--;
    if (!-e $___CONFIG) { die "Couldn't find config file: $___CONFIG. Exiting!!\n"; }
}
else {
    $run=$start_run-1;
    my $config_abs = ensure_full_path($___CONFIG);
    die "File not found: $___CONFIG (interpreted as $config_abs)."
	if ! -e $config_abs;
    $___CONFIG = $config_abs;
}

# check validity of moses.ini and collect number of models and lambdas per model
# need to make a copy of $extra_lambdas_for_model, scan_config spoils it
#my %copy_of_extra_lambdas_for_model = %$extra_lambdas_for_model;
my %used_triples = %{$default_triples};
my ($models_used) = scan_config($___CONFIG);


# Parse the lambda config string and convert it to a nice structure in the same format as $used_triples
if (defined $___LAMBDA) {
  my %specified_triples;
  # interpreting lambdas from command line
  foreach (split(/\s+/,$___LAMBDA)) {
      my ($name,$values) = split(/:/);
      die "Malformed setting: '$_', expected name:values\n" if !defined $name || !defined $values;
      foreach my $startminmax (split/;/,$values) {
	  if ($startminmax =~ /^(-?[\.\d]+),(-?[\.\d]+)-(-?[\.\d]+)$/) {
	      my $start = $1;
	      my $min = $2;
	      my $max = $3;
              push @{$specified_triples{$name}}, [$start, $min, $max];
	  }
	  else {
	      die "Malformed feature range definition: $name => $startminmax\n";
	  }
      } 
  }
  # sanity checks for specified lambda triples
  foreach my $name (keys %used_triples) {
      die "No lambdas specified for '$name', but ".($#{$used_triples{$name}}+1)." needed.\n"
	  unless defined($specified_triples{$name});
      die "Number of lambdas specified for '$name' (".($#{$specified_triples{$name}}+1).") does not match number needed (".($#{$used_triples{$name}}+1).")\n"
	  if (($#{$used_triples{$name}}) != ($#{$specified_triples{$name}}));
  }
  foreach my $name (keys %specified_triples) {
      die "Lambdas specified for '$name' ".(@{$specified_triples{$name}}).", but none needed.\n"
	  unless defined($used_triples{$name});
  }
  %used_triples = %specified_triples;
}

# moses should use our config
if ($___DECODER_FLAGS =~ /(^|\s)-(config|f) /
|| $___DECODER_FLAGS =~ /(^|\s)-(ttable-file|t) /
|| $___DECODER_FLAGS =~ /(^|\s)-(distortion-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(generation-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(lmodel-file) /
) {
  die "It is forbidden to supply any of -config, -ttable-file, -distortion-file, -generation-file or -lmodel-file in the --decoder-flags.\nPlease use only the --config option to give the config file that lists all the supplementary files.";
}

# as weights are normalized in the next steps (by cmert)
# normalize initial LAMBDAs, too
my $need_to_normalize = 0;


my @order_of_lambdas_from_decoder = ();
# this will store the labels of scores coming out of the decoder (and hence the order of lambdas coming out of mert)
# we will use the array to interpret the lambdas
# the array gets filled with labels only after first nbestlist was generated


#store current directory and create the working directory (if needed)
my $cwd = `pawd 2>/dev/null`; 
if(!$cwd){$cwd = `pwd`;}
chomp($cwd);

safesystem("mkdir -p $___WORKING_DIR") or die "Can't mkdir $___WORKING_DIR";

{
# open local scope

#chdir to the working directory
chdir($___WORKING_DIR) or die "Can't chdir to $___WORKING_DIR";

# fixed file names
my $mert_logfile = "mert.log";
my $weights_in_file = "init.opt";
my $weights_out_file = "weights.txt";


if ($continue) {
#  die "continue not yet supported by the new mert script\nNeed to load features and scores from last iteration\n";
  # need to load last best values
  print STDERR "Trying to continue an interrupted optimization.\n";
  open IN, "finished_step.txt" or die "Failed to find the step number, failed to read finished_step.txt";
  my $step = <IN>;
  chomp $step;
  $step++;
  close IN;

  if (! -e "run$step.best$___N_BEST_LIST_SIZE.out.gz") {
    # allow stepping one extra iteration back
    $step--;
    die "Can't start from step $step, because run$step.best$___N_BEST_LIST_SIZE.out.gz was not found!"
      if ! -e "run$step.best$___N_BEST_LIST_SIZE.out.gz";
  }

  $start_run = $step +1;

  print STDERR "Reading last cached lambda values (result from step $step)\n";
  @order_of_lambdas_from_decoder = get_order_of_scores_from_nbestlist("gunzip -c < run$step.best$___N_BEST_LIST_SIZE.out.gz |");

  open IN, "$weights_out_file" or die "Can't read $weights_out_file";
  my $newweights = <IN>;
  chomp $newweights;
  close IN;
  my @newweights = split /\s+/, $newweights;

  #dump_triples(\%used_triples);
  store_new_lambda_values(\%used_triples, \@order_of_lambdas_from_decoder, \@newweights);
  #dump_triples(\%used_triples);
}

if ($___FILTER_PHRASE_TABLE){
  # filter the phrase tables wih respect to input, use --decoder-flags
  print "filtering the phrase tables... ".`date`;
  my $cmd = "$filtercmd ./filtered $___CONFIG $___DEV_F";
  if (defined $___JOBS) {
    safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -queue-parameter=\"$queue_flags\" -stdout=filterphrases.out -stderr=filterphrases.err" )
      or die "Failed to submit filtering of tables to the queue (via $qsubwrapper)";
  } else {
    safesystem($cmd) or die "Failed to filter the tables.";
  }

  # make a backup copy of startup ini file
  $___CONFIG_BAK = $___CONFIG;
  # the decoder should now use the filtered model
  $___CONFIG = "filtered/moses.ini";
}
else{
  # do not filter phrase tables (useful if binary phrase tables are available)
  # use the original configuration file
  $___CONFIG_BAK = $___CONFIG;
}


my $PARAMETERS;
#$PARAMETERS = $___DECODER_FLAGS . " -config $___CONFIG -inputtype $___INPUTTYPE";
$PARAMETERS = $___DECODER_FLAGS;

my $devbleu = undef;
my $bestpoint = undef;

my $oldallsorted = undef;
my $allsorted = undef;

my $prev_aggregate_nbl_size = -1;

my $cmd;
# features and scores from the last run.
my $prev_feature_file=undef;
my $prev_score_file=undef;
my $nbest_file=undef;
if ($mert_status != 100) {
    my $prev_run = $run;
    $prev_feature_file = "run$prev_run.features.dat.gz";
    $prev_score_file = "run$prev_run.scores.dat.gz";
    if (!-e $prev_feature_file || !-e $prev_score_file) { &xtract_past_stats($prev_run); }
    print "Using feature and score files from prev iteration: $prev_feature_file ** $prev_score_file\n";
}

while(1) {
  $run++;
  # run beamdecoder with option to output nbestlists
  # the end result should be (1) @NBEST_LIST, a list of lists; (2) @SCORE, a list of lists of lists

  print "run $run start at ".`date`;

  # In case something dies later, we might wish to have a copy
  if ( !-e "./run$run.moses.ini" ) {
    create_config($___CONFIG, "./run$run.moses.ini", \%used_triples, $run, (defined$devbleu?$devbleu:"--not-estimated--"));
  }

  # skip if the user wanted
  if (!$skip_decoder) {
      print "($run) run decoder to produce n-best lists\n";
      $nbest_file = run_decoder(\%used_triples, $PARAMETERS, $run, \@order_of_lambdas_from_decoder, $need_to_normalize);
      $need_to_normalize = 0;
      safesystem("gzip -f $nbest_file") or die "Failed to gzip run*out";
      $nbest_file = $nbest_file.".gz";
  }
  else {
      die "Skipping not yet supported\n";
      #print "skipped decoder run\n";
      #if (0 == scalar @order_of_lambdas_from_decoder) {
      #  @order_of_lambdas_from_decoder = get_order_of_scores_from_nbestlist("gunzip -dc run*.best*.out.gz | head -1 |");
      #}
      #$skip_decoder = 0;
      #$need_to_normalize = 0;
  }

  # extract score statistics and features from the nbest lists
  print STDERR "Scoring the nbestlist.\n";
  my $feature_file = "run$run.features.dat";
  my $score_file = "run$run.scores.dat";
  $cmd = "$mert_extract_cmd $mertargs --scfile $score_file --ffile $feature_file -r ".join(",", @references)." -n $nbest_file";
  if (defined $prev_feature_file) {
      $cmd = $cmd." --prev-ffile $prev_feature_file";
  }
  if (defined $prev_score_file) {
      $cmd = $cmd." --prev-scfile $prev_score_file";
  }
  if (defined $___JOBS) {
    #safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -queue-parameter=\"$queue_flags\" -stdout=extract.out -stderr=extract.err" )
    #  or die "Failed to submit extraction to queue (via $qsubwrapper)";
    safesystem("$cmd > extract.out 2> extract.err") or die "Failed to do extraction of statistics.";
  } else {
    safesystem("$cmd > extract.out 2> extract.err") or die "Failed to do extraction of statistics.";
  }

  # Create the initial weights file for mert, in init.opt
  # mert reads in the file init.opt containing the current
  # values of lambda.

  # We need to prepare the files and **the order of the lambdas must
  # correspond to the order @order_of_lambdas_from_decoder

  # NB: This code is copied from the old version of mert-moses.pl,
  # even though the max,min and name are not yet used in the new
  # version.
  my @MIN = ();   # lower bounds
  my @MAX = ();   # upper bounds
  my @CURR = ();   # the starting values
  my @NAME = ();  # to which model does the lambda belong
  
  # walk in order of @order_of_lambdas_from_decoder and collect the min,max,val
  my %visited = ();
  foreach my $name (@order_of_lambdas_from_decoder) {
    next if $visited{$name};
    $visited{$name} = 1;
	if (!defined $used_triples{$name})
	{
    	die "The decoder produced also some '$name' scores, but we do not know the ranges for them, no way to optimize them\n";
	}
      
    my $count = 0;
    foreach my $feature (@{$used_triples{$name}}) {
	$count++;
	my ($val, $min, $max) = @$feature;
	push @CURR, $val;
	push @MIN, $min;
	push @MAX, $max;
	push @NAME, $name;
    }
  }

  open(OUT,"> $weights_in_file") or die "Can't write $weights_in_file (WD now $___WORKING_DIR)";
  print OUT join(" ", @CURR)."\n";
  close(OUT);
  
  # make a backup copy labelled with this run number
  safesystem("\\cp -f $weights_in_file run$run.$weights_in_file") or die;

  my $DIM = scalar(@CURR); # number of lambdas

  # run mert
  $cmd = "$mert_mert_cmd -d $DIM $mertargs -n 20 --scfile $score_file --ffile $feature_file";
  if (defined $___JOBS) {
    #safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -stderr=$mert_logfile -queue-parameter=\"$queue_flags\"") or die "Failed to start mert (via qsubwrapper $qsubwrapper)";
    safesystem("$cmd 2> $mert_logfile") or die "Failed to run mert";
  } else {
    safesystem("$cmd 2> $mert_logfile") or die "Failed to run mert";
  }
  die "Optimization failed, file $weights_out_file does not exist or is empty"
    if ! -s $weights_out_file;

 # backup copies
  safesystem ("gzip $feature_file; ") or die;
  safesystem ("gzip $score_file") or die;
  safesystem ("\\cp -f $mert_logfile run$run.$mert_logfile") or die;
  safesystem ("\\cp -f $weights_out_file run$run.$weights_out_file") or die; # this one is needed for restarts, too
  $mert_status = ($run + 1)."00";
 
  print "run $run end at ".`date`;

  $bestpoint = undef;
  $devbleu = undef;
  open(IN,"$mert_logfile") or die "Can't open $mert_logfile";
  while (<IN>) {
    if (/Best point:\s*([\s\d\.e\-]+?)\s*=> ([\d\.]+)/) {
      $bestpoint = $1;
      $devbleu = $2;
      last;
    }
  }
  close IN;
  die "Failed to parse mert.log, missed Best point there."
    if !defined $bestpoint || !defined $devbleu;
  print "($run) BEST at $run: $bestpoint => $devbleu at ".`date`;

  my @newweights = split /\s+/, $bestpoint;

  # update my cache of lambda values
  store_new_lambda_values(\%used_triples, \@order_of_lambdas_from_decoder, \@newweights);

  ## additional stopping criterion: weights have not changed
  my $shouldstop = 1;
  for(my $i=0; $i<@CURR; $i++) {
    die "Lost weight! mert reported fewer weights (@newweights) than we gave it (@CURR)"
      if !defined $newweights[$i];
    if (abs($CURR[$i] - $newweights[$i]) >= $minimum_required_change_in_weights) {
      $shouldstop = 0;
      last;
    }
  }

  open F, "> finished_step.txt" or die "Can't mark finished step";
  print F $run."\n";
  close F;


  if ($shouldstop) {
    print STDERR "None of the weights changed more than $minimum_required_change_in_weights. Stopping.\n";
    last;
  }
  
  $prev_feature_file = $feature_file.".gz";
  $prev_score_file = $score_file.".gz";
#  safesystem("\\rm -f run$run.out") or die;

}
print "Training finished at ".`date`;

if (defined $allsorted){ safesystem ("\\rm -f $allsorted") or die; };

safesystem("\\cp -f $weights_in_file run$run.$weights_in_file") or die;
safesystem("\\cp -f $mert_logfile run$run.$mert_logfile") or die;

create_config($___CONFIG_BAK, "./moses.ini", \%used_triples, $run, $devbleu);

# just to be sure that we have the really last finished step marked
open F, "> finished_step.txt" or die "Can't mark finished step";
print F $run."\n";
close F;


#chdir back to the original directory # useless, just to remind we were not there
chdir($cwd);

} # end of local scope

sub xtract_past_stats {
    my $prev_run = shift;
    my $curr_nbest_file;
    my $curr_feature_file = "";
    my $curr_score_file = "";
    my $past_feature_file;
    my $past_score_file;
    my $cmd;
    my $r;

    print STDERR "\n###\nINFO: Extracting feature and score files for earlier runs ...\n###\n";
    for ($r=1; $r<=$prev_run; $r++) {
        $curr_nbest_file = "run${r}.best100.out.gz";
        if (!-e $curr_nbest_file) {
            if(!-e "run${r}.best100.out") {
                die "For resuming MERT after interruption either nbest files or feature and score files from earlier runs are required. Exiting!!\n";
            }
            safesystem("gzip -f run${r}.best100.out") or die "Failed to gzip run*out";
        }

        $curr_feature_file = "run${r}.features.dat";
        $curr_score_file = "run${r}.scores.dat";
        $cmd = "$mert_extract_cmd $mertargs --scfile $curr_score_file --ffile $curr_feature_file -r ".join(",", @references)." -n $curr_nbest_file";
        if (defined $past_feature_file) { $cmd = $cmd." --prev-ffile $past_feature_file"; }
        if (defined $past_score_file) { $cmd = $cmd." --prev-scfile $past_score_file"; }
        if (defined $___JOBS) {
            #safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -queue-parameter=\"$queue_flags\" -stdout=extract.out -stderr=extract.err" )
            #            or die "Failed to submit extraction to queue (via $qsubwrapper)";
            safesystem("$cmd > extract.out 2> extract.err") or die "Failed to do extraction of statistics.";
        } else {
            safesystem("$cmd > extract.out 2> extract.err") or die "Failed to do extraction of statistics.";
        }

        safesystem ("gzip $curr_feature_file; ") or die;
        safesystem ("gzip $curr_score_file") or die;
        $past_feature_file = $curr_feature_file.".gz";
        $past_score_file = $curr_score_file.".gz";
    }
}

sub store_new_lambda_values {
  # given new lambda values (in given order), replace the 'val' element in our triples
  my $triples = shift;
  my $names = shift;
  my $values = shift;

  my %idx = ();
  foreach my $i (0..scalar(@$values)-1) {
    my $name = $names->[$i];
    die "Missed name for lambda $values->[$i] (in @$values; names: @$names)"
      if !defined $name;
    if (!defined $idx{$name}) {
      $idx{$name} = 0;
    } else {
      $idx{$name}++;
    }
    die "We did not optimize '$name', but moses returned it back to us"
      if !defined $triples->{$name};
    die "Moses gave us too many lambdas for '$name', we had ".scalar(@{$triples->{$name}})
      ." but we got at least ".$idx{$name}+1
      if !defined $triples->{$name}->[$idx{$name}];

    # set the corresponding field in triples
    # print STDERR "Storing $i-th score as $name: $idx{$name}: $values->[$i]\n";
    $triples->{$name}->[$idx{$name}]->[0] = $values->[$i];
  }
}

sub dump_triples {
  my $triples = shift;

  foreach my $name (keys %$triples) {
    foreach my $triple (@{$triples->{$name}}) {
      my ($val, $min, $max) = @$triple;
      print STDERR "Triples:  $name\t$val\t$min\t$max    ($triple)\n";
    }
  }
}


sub run_decoder {
    my ($triples, $parameters, $run, $output_order_of_lambdas, $need_to_normalize) = @_;
    my $filename_template = "run%d.best$___N_BEST_LIST_SIZE.out";
    my $filename = sprintf($filename_template, $run);
    
    print "params = $parameters\n";
    # prepare the decoder config:
    my $decoder_config = "";
    my @vals = ();
    foreach my $name (keys %$triples) {
      $decoder_config .= "--$name ";
      foreach my $triple (@{$triples->{$name}}) {
        my ($val, $min, $max) = @$triple;
        $decoder_config .= "%.6f ";
        push @vals, $val;
      }
    }
    if ($need_to_normalize) {
      print STDERR "Normalizing lambdas: @vals\n";
      my $totlambda=0;
      grep($totlambda+=abs($_),@vals);
      grep($_/=$totlambda,@vals);
    }
    print STDERR "DECODER_CFG = $decoder_config\n";
    print STDERR "     values = @vals\n";
    $decoder_config = sprintf($decoder_config, @vals);
    print "decoder_config = $decoder_config\n";

    # run the decoder
    my $nBest_cmd = "-n-best-size $___N_BEST_LIST_SIZE";
    my $decoder_cmd;

    if (defined $___JOBS) {
        if (defined $___RM_RULES){
            if ( -f $___SCFG_RULES ) {              # For specifying the ttable-file directly
	        $decoder_cmd = "$moses_parallel_cmd $pass_old_sge -config $___CONFIG -kriya-options \"$kriya_opts\" -qsub-prefix mert$run -queue-parameters \"$queue_flags\" -mert-status $mert_status -prev-jobid $prev_jobid -n-best-list $filename -n-best-size $___N_BEST_LIST_SIZE -input-dir $___DEV_F -output-dir $___WORKING_DIR --ttable-file $___SCFG_RULES --rm-file $___RM_RULES --lmfile $___LM_FILE -jobs $___JOBS -decoder-prefix $___DECODER_PREFIX -decoder $___DECODER -nodes-prop \"$nodes_prop\" > run$run.out";
            }
            elsif ( -d $___SCFG_RULES ) {           # For specifying the rule-dir having the ttable-files
	        $decoder_cmd = "$moses_parallel_cmd $pass_old_sge -config $___CONFIG -kriya-options \"$kriya_opts\" -qsub-prefix mert$run -queue-parameters \"$queue_flags\" -mert-status $mert_status -prev-jobid $prev_jobid -n-best-list $filename -n-best-size $___N_BEST_LIST_SIZE -input-dir $___DEV_F -output-dir $___WORKING_DIR -rule-dir $___SCFG_RULES -rm-dir $___RM_RULES --lmfile $___LM_FILE -jobs $___JOBS -decoder-prefix $___DECODER_PREFIX -decoder $___DECODER -nodes-prop \"$nodes_prop\" > run$run.out";
            }
        } else {
            if ( -f $___SCFG_RULES ) {              # For specifying the ttable-file directly
	        $decoder_cmd = "$moses_parallel_cmd $pass_old_sge -config $___CONFIG -kriya-options \"$kriya_opts\" -qsub-prefix mert$run -queue-parameters \"$queue_flags\" -mert-status $mert_status -prev-jobid $prev_jobid -n-best-list $filename -n-best-size $___N_BEST_LIST_SIZE -input-dir $___DEV_F -output-dir $___WORKING_DIR --ttable-file $___SCFG_RULES --lmfile $___LM_FILE -jobs $___JOBS -decoder-prefix $___DECODER_PREFIX -decoder $___DECODER -nodes-prop \"$nodes_prop\" > run$run.out";
            }
            elsif ( -d $___SCFG_RULES ) {           # For specifying the rule-dir having the ttable-files
	        $decoder_cmd = "$moses_parallel_cmd $pass_old_sge -config $___CONFIG -kriya-options \"$kriya_opts\" -qsub-prefix mert$run -queue-parameters \"$queue_flags\" -mert-status $mert_status -prev-jobid $prev_jobid -n-best-list $filename -n-best-size $___N_BEST_LIST_SIZE -input-dir $___DEV_F -output-dir $___WORKING_DIR -rule-dir $___SCFG_RULES --lmfile $___LM_FILE -jobs $___JOBS -decoder-prefix $___DECODER_PREFIX -decoder $___DECODER -nodes-prop \"$nodes_prop\" > run$run.out";
            }
        }
    } else {
      my $sentIndex = 100;
      my $in_file = $___DEV_F;
      my $rule_file = $___SCFG_RULES;
      my $rm_file = $___RM_RULES;
      my $out_file = $___WORKING_DIR."/".$sentIndex.".out";
      $sentIndex = 0;       # Reset the sentIndex to 1
      $decoder_cmd = "$___DECODER_PREFIX $___DECODER $parameters --config $___CONFIG $kriya_opts --index $sentIndex --inputfile $in_file --outputfile $filename --glue-file $___GLUE_RULES --ttable-file $rule_file --rm-file $rm_file --lmodel-file $___LM_FILE > run$run.out";
#      $decoder_cmd = "$___DECODER_PREFIX $___DECODER $parameters --config $___CONFIG $decoder_config -n-best-list $filename $___N_BEST_LIST_SIZE -i $___DEV_F > run$run.out";
    }

    safesystem($decoder_cmd) or die "The decoder died. CONFIG WAS $decoder_config \n";
    $prev_jobid = 0 if defined $prev_jobid;

    if (0 == scalar @$output_order_of_lambdas) {
      # we have to peek at the nbestlist
      @$output_order_of_lambdas = get_order_of_scores_from_nbestlist($filename);
    } 
    # we have checked the nbestlist already, we trust the order of output scores does not change
    return $filename;
}

sub get_order_of_scores_from_nbestlist {
  # read the first line and interpret the ||| label: num num num label2: num ||| column in nbestlist
  # return the score labels in order
  my $fname_or_source = shift;
  print STDERR "Peeking at the beginning of nbestlist to get order of scores: $fname_or_source\n";
  open IN, $fname_or_source or die "Failed to get order of scores from nbestlist '$fname_or_source'";
  my $line = <IN>;
  close IN;
  die "Line empty in nbestlist '$fname_or_source'" if !defined $line;
  my ($sent, $hypo, $scores, $total) = split /\|\|\|/, $line;
  $scores =~ s/^\s*|\s*$//g;
  die "No scores in line: $line" if $scores eq "";

  my @order = ();
  my $label = undef;
  foreach my $tok (split /\s+/, $scores) {
    if ($tok =~ /^([a-z][0-9a-z]*):/i) {
      $label = $1;
    } elsif ($tok =~ /^-?[-0-9.e]+$/) {
      # a score found, remember it
      die "Found a score but no label before it! Bad nbestlist '$fname_or_source'!"
        if !defined $label;
      push @order, $label;
    } else {
      die "Not a label, not a score '$tok'. Failed to parse the scores string: '$scores' of nbestlist '$fname_or_source'";
    }
  }
  print STDERR "The decoder returns the scores in this order: @order\n";
  return @order;
}

sub create_config {
    my $infn = shift; # source config
    my $outfn = shift; # where to save the config
    my $triples = shift; # the lambdas we should write
    my $iteration = shift;  # just for verbosity
    my $bleu_achieved = shift; # just for verbosity

    my %P; # the hash of all parameters we wish to override

    # first convert the command line parameters to the hash
    { # ensure local scope of vars
	my $parameter=undef;
	print "Parsing --decoder-flags: |$___DECODER_FLAGS|\n";
        $___DECODER_FLAGS =~ s/^\s*|\s*$//;
        $___DECODER_FLAGS =~ s/\s+/ /;
	foreach (split(/ /,$___DECODER_FLAGS)) {
	    if (/^\-([^\d].*)$/) {
		$parameter = $1;
		$parameter = $ABBR2FULL{$parameter} if defined($ABBR2FULL{$parameter});
	    }
	    else {
                die "Found value with no -paramname before it: $_"
                  if !defined $parameter;
		push @{$P{$parameter}},$_;
	    }
	}
    }

    # Convert weights to elements in P
    foreach my $abbr (keys %$triples) {
      # First delete all weights params from the input, in short or long-named version
      delete($P{$abbr});
      delete($P{$ABBR2FULL{$abbr}});
      # Then feed P with the current values
      foreach my $feature (@{$used_triples{$abbr}}) {
        my ($val, $min, $max) = @$feature;
        my $name = defined $ABBR2FULL{$abbr} ? $ABBR2FULL{$abbr} : $abbr;
        push @{$P{$name}}, $val;
      }
    }

    # create new moses.ini decoder config file by cloning and overriding the original one
    if ($mert_status !~ /^[^1]\d\d$/ && -e $___CONFIG) {
	print STDERR "$infn\n";
	print STDERR "Config file $___CONFIG exists. Not copying the initial config file\n";
    }

    open(INI,$infn) or die "Can't read $infn";
    delete($P{"config"}); # never output 
    print "Saving new config to: $outfn\n";
    open(OUT,"> $outfn") or die "Can't write $outfn";
    print OUT "# MERT optimized configuration\n";
    print OUT "# decoder $___DECODER\n";
    print OUT "# BLEU $bleu_achieved on dev $___DEV_F\n";
    print OUT "# We were before running iteration $iteration\n";
    print OUT "# finished ".`date`;
    my $line = <INI>;
    while(1) {
	last unless $line;

	# skip until hit [parameter]
	if ($line !~ /^\[(.+)\]\s*$/) { 
	    $line = <INI>;
	    print OUT $line if $line =~ /^\#/ || $line =~ /^\s+$/;
	    next;
	}

	# parameter name
	my $parameter = $1;
	$parameter = $ABBR2FULL{$parameter} if defined($ABBR2FULL{$parameter});
	print OUT "[$parameter]\n";

	# change parameter, if new values
	if (defined($P{$parameter})) {
	    # write new values
	    foreach (@{$P{$parameter}}) {
		print OUT $_."\n";
	    }
	    delete($P{$parameter});
	    # skip until new parameter, only write comments
	    while($line = <INI>) {
		print OUT $line if $line =~ /^\#/ || $line =~ /^\s+$/;
		last if $line =~ /^\[/;
		last unless $line;
	    }
	    next;
	}
	
	# unchanged parameter, write old
	while($line = <INI>) {
	    last if $line =~ /^\[/;
	    print OUT $line;
	}
    }

    # write all additional parameters
    foreach my $parameter (keys %P) {
	print OUT "\n[$parameter]\n";
	foreach (@{$P{$parameter}}) {
	    print OUT $_."\n";
	}
    }

    close(INI);
    close(OUT);
    print STDERR "Saved: $outfn\n";
    $___CONFIG = $outfn;
}

sub safesystem {
  print STDERR "Executing: @_\n";
  system(@_);
  if ($? == -1) {
      print STDERR "Failed to execute: @_\n  $!\n";
      exit(1);
  }
  elsif ($? & 127) {
      printf STDERR "Execution of: @_\n  died with signal %d, %s coredump\n",
          ($? & 127),  ($? & 128) ? 'with' : 'without';
      exit(1);
  }
  else {
    my $exitcode = $? >> 8;
    print STDERR "Exit code: $exitcode\n" if $exitcode;
    return ! $exitcode;
  }
}
sub ensure_full_path {
    my $PATH = shift;
    $PATH =~ s/\/nfsmnt//;
    return $PATH if $PATH =~ /^\//;
    my $dir = `pawd 2>/dev/null`; 
    if(!$dir){$dir = `pwd`;}
    chomp($dir);
    $PATH = $dir."/".$PATH;
    $PATH =~ s/[\r\n]//g;
    $PATH =~ s/\/\.\//\//g;
    $PATH =~ s/\/+/\//g;
    my $sanity = 0;
    while($PATH =~ /\/\.\.\// && $sanity++<10) {
        $PATH =~ s/\/+/\//g;
        $PATH =~ s/\/[^\/]+\/\.\.\//\//g;
    }
    $PATH =~ s/\/[^\/]+\/\.\.$//;
    $PATH =~ s/\/+$//;
    $PATH =~ s/\/nfsmnt//;
    return $PATH;
}




sub scan_config {
    my $ini = shift;
    print "Scanning file: $ini\n\n";
    my $inishortname = $ini; $inishortname =~ s/^.*\///; # for error reporting
    # we get a pre-filled counts, because some lambdas are always needed (word penalty, for instance)
    # as we walk though the ini file, we record how many extra lambdas do we need
    # and finally, we report it

    # in which field (counting from zero) is the filename to check?
    my %where_is_filename = (
			     "ttable-file" => 1,
			     "generation-file" => 3,
			     "lmodel-file" => 1,
			     "distortion-file" => 3,
			     );
    # by default, each line of each section means one lambda, but some sections
    # explicitly state a custom number of lambdas
    my %where_is_lambda_count = (
				 "ttable-file" => 0,
				 "generation-file" => 2,
				 "distortion-file" => 2,
				 );
  
    open INI, $ini or die "Can't read $ini";

    my $section = undef;  # name of the section we are reading
    my $shortname = undef;  # the corresponding short name
    my $nr = 0;
    my $error = 0;
    my %defined_files;
    my %defined_steps;  # check the ini file for compatible mapping steps and actually defined files
    while (<INI>) {
	$nr++;
	next if /^\s*#/; # skip comments
	if (/^\[([^\]]*)\]\s*$/) {
            $shortname = undef;
	    $section = $1;
	    if (defined $TABLECONFIG2ABBR{$section}) { $shortname = $TABLECONFIG2ABBR{$section}; }
	    elsif (defined $FULL2ABBR{$section}) { $shortname = $FULL2ABBR{$section}; }
	    next;
	}

	if (defined $section && $section eq "mapping") {
	    # keep track of mapping steps used
	    $defined_steps{$1}++ if /^([TG])/ || /^\d+ ([TG])/;
	}

	if (defined $section && defined $where_is_filename{$section}) {
	    # this ini section is relevant to lambdas
	    chomp;
	    next if ($_ eq '');

	    my @flds = split / +/;
	    my $fn = $flds[$where_is_filename{$section}];

	    if (defined $fn && $fn !~ /^\s+$/) {
		print "checking weight-count for $section\n";
		# this is a filename! check it
		if ($fn !~ /^\//) {
		    $error = 1;
		    print STDERR "$inishortname:$nr:Filename not absolute: $fn\n";
		}
		if (! -s $fn && ! -s "$fn.gz" && ! -s "$fn.binphr.idx") {
		    $error = 1;
		    print STDERR "$inishortname:$nr:File does not exist or empty: $fn\n";
		}
		# remember the number of files used, to know how many lambdas do we need
		die "No short name was defined for section $section!"
		    if ! defined $shortname;

		# how many lambdas does this model need?
		# either specified explicitly, or the default, i.e. one
		my $needlambdas = defined $where_is_lambda_count{$section} ? $flds[$where_is_lambda_count{$section}] : 1;

		print STDERR "Config needs $needlambdas lambdas for $section (i.e. $shortname)\n" if $verbose;
		if (!defined $___LAMBDA && (!defined $additional_triples->{$shortname} || scalar(@{$additional_triples->{$shortname}}) < $needlambdas)) {
		    print STDERR "$inishortname:$nr:Your model $shortname needs $needlambdas weights but we define the default ranges for only "
			.scalar(@{$additional_triples->{$shortname}})." weights. Cannot use the default, you must supply lambdas by hand.\n";
		    $error = 1;
		}
		else {
		    # note: table may use less parameters than the maximum number
		    # of triples
		    for(my $lambda=0;$lambda<$needlambdas;$lambda++) {
			my ($start, $min, $max) 
			    = @{${$additional_triples->{$shortname}}[$lambda]};
			push @{$used_triples{$shortname}}, [$start, $min, $max];
		    }
		}
		$defined_files{$shortname}++;
	    }
	}
	elsif (defined $shortname) {
	    my $lambda_cnt = 0;
	    my $new_start;
	    my $needlambdas = defined $additional_triples->{$shortname} ? scalar(@{$additional_triples->{$shortname}}) : 1;
	    while ( $lambda_cnt < $needlambdas ) {
		chomp($_);
		${$used_triples{$shortname}}[$lambda_cnt]->[0] = $_;
		$lambda_cnt++;
		$_ = <INI>;
	    }
	    undef $shortname;
	}
    }
    die "$inishortname: File was empty!" if !$nr;
    close INI;

#    for my $pair (qw/T=tm=translation G=g=generation/) {
#	my ($tg, $shortname, $label) = split /=/, $pair;
#	$defined_files{$shortname} = 0 if ! defined $defined_files{$shortname};
#	$defined_steps{$tg} = 0 if ! defined $defined_steps{$tg};
#
#	if ($defined_files{$shortname} != $defined_steps{$tg}) {
#	    print STDERR "$inishortname: You defined $defined_files{$shortname} files for $label but use $defined_steps{$tg} in [mapping]!\n";
#	    $error = 1;
#	}
#    }

    exit(1) if $error;
    return (\%defined_files);
}

