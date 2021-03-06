#!/usr/bin/perl -w
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use FindBin qw($Bin $Script);
use File::Basename qw(basename dirname);
require "$Bin/mylib.pl";
my $BEGIN_TIME=time();
my $version="2.0.0";

#######################################################################################

# ------------------------------------------------------------------
# GetOptions
# ------------------------------------------------------------------
my ($fsample_sheet,$indir, $num_parallel, $threads, $outdir, $only);
my ($min_CV, $min_depth, $flexbar);
my ($Abnormal_Recognize,$Double_Barcode);
my ($SingleEnd, $step);
my ($secBar_len, $mismatch_bar1, $mismatch_bar2);
my $max_size=2000;
my $min_depth_snp = 100;
my $configID = "xxx";
my $ref = "$Bin/config/hg19.fasta";
my $fpanel = "$Bin/config/panel.config";
my $fbarcode = "$Bin/config/barcode.config";
GetOptions(
				"help|?" =>\&USAGE,
				"ss:s"=>\$fsample_sheet,
				"pc:s"=>\$fpanel,
				"bc:s"=>\$fbarcode,
				"ref:s"=>\$ref,
				"id:s"=>\$configID,
				"indir:s"=>\$indir,
				"SingleEnd:s"=>\$SingleEnd,
				"Abnormal_Recognize:s"=>\$Abnormal_Recognize,
				"Double_Barcode:s"=>\$Double_Barcode,
				"parallel:s"=>\$num_parallel,
				"threads:s"=>\$threads,
				"min_depth:s"=>\$min_depth,
				"min_CV:s"=>\$min_CV,
				"secBar_len:s"=>\$secBar_len,
				"mismatch_bar1:s"=>\$mismatch_bar1,
				"mismatch_bar2:s"=>\$mismatch_bar2,
				"step:s"=>\$step,
				"only:s"=>\$only,
				"outdir:s"=>\$outdir,
				"mdepth_snp:s"=>\$min_depth_snp,
				"msize:i"=>\$max_size,
				) or &USAGE;
&USAGE unless ($fsample_sheet and $indir and $configID);
$outdir||="./";
`mkdir $outdir`	unless (-d $outdir);
$outdir=AbsolutePath("dir",$outdir);
$fsample_sheet=AbsolutePath("file", $fsample_sheet);

$num_parallel = defined $num_parallel? $num_parallel: 4;
$min_CV = defined $min_CV? $min_CV: 0.65;
$min_depth = defined $min_depth? $min_depth: 4;
$threads = defined $threads? $threads: 6;
$step = defined $step? $step: 0;
$secBar_len = defined $secBar_len? $secBar_len: 9;
$mismatch_bar1 = defined $mismatch_bar1? $mismatch_bar1: 1;
$mismatch_bar2 = defined $mismatch_bar2? $mismatch_bar2: 1;

print "\nStart time: ",GetTime(),"\n";

## mkdir statistic
my $dir_statistic ="$outdir/statistic";
`mkdir $dir_statistic` unless(-d $dir_statistic);
my $log_dir = "$outdir/log/";
mkdir $log_dir unless (-d $log_dir);

my $continuous_mutation="$dir_statistic/continuous.mutation";
&check_continuous_mutation($continuous_mutation);

my $sh;
open ($sh,">$outdir/work.sh") or die $!;

#==================================================================
# read data config
#==================================================================
my %data_config;
&read_data_sheet($fsample_sheet, $fpanel, \%data_config, $configID);
&output_sample_description(\%data_config, $dir_statistic);  ## out sample description

#==================================================================
# call data of double barcode 
#==================================================================
my $dir_call = "$outdir/00.call_data";
if($step ==0){
	if(defined $Double_Barcode){
		`mkdir $dir_call` unless (-d $dir_call);
	 	&Run("$Bin/ctBest/ctbest demulex -i $indir -s $fsample_sheet -o $dir_call -2 -l 7 -b 7", $sh);
	}
	$step++;
}


#==================================================================
# detect 
#==================================================================
if ($step <=5) {
	&detect(\%data_config, $fsample_sheet, $indir, $outdir, $step);
	print "\nDetect Done: ",GetTime(),"\n";
	$step = 6;
}

#==================================================================
# get hotspot result; genotyping
#==================================================================
if ($step == 6){
	&Run("perl $Bin/get_hotspot_detect.pl -id $outdir/05.variant_detect/variants/ -is $fsample_sheet -ic $fpanel -cid $configID  -k Total -od $dir_statistic", $sh);
	my $dir_genotype = "$outdir/06.genotyping";
	`mkdir $dir_genotype` unless (-d $dir_genotype);
	&Run("perl $Bin/tma_genotyping/cffdna_estimation_and_fetal_genotyping.pl -i $fsample_sheet -ic $fpanel -cid $configID -id $outdir/statistic/05.hotspots_result/ -k Total -od $dir_genotype -e -d $min_depth_snp", $sh);
	$step ++;
}

#==================================================================
# merge statistic and abnormal sample recognize
#==================================================================
if ($step == 7) {
	my %abnormal_samp;
	&statistic($outdir, $dir_statistic);
	if (defined $Abnormal_Recognize){
		&abnormal_sample_recognize(\%data_config,$dir_statistic, \%abnormal_samp);
	}
	$step ++;
}

print "\nTotal Done : ",GetTime(),"\n";
close ($sh) ;
#######################################################################################
print STDOUT "\nDone. Total elapsed time : ",time()-$BEGIN_TIME,"s\n";
#######################################################################################

# ------------------------------------------------------------------
# sub function
# ------------------------------------------------------------------

sub abnormal_sample_recognize{ 
	my ($adc,$dir_statistic,$asample_abn)=@_;
	&abnormal_recognize($adc, $dir_statistic, $asample_abn, "LowReads", 3000000, "Low");
	&abnormal_recognize($adc, $dir_statistic, $asample_abn, "LowDepth", 800, "Low");

	open (AB,">$dir_statistic/Abnormal.result") or die $!;
	print AB "SampleID\tAbnormalType\tAbnormalValue\n";
	foreach my $sample (sort {$a cmp $b} keys %{$asample_abn}) {

		print AB $sample,"\t",join(",",@{$asample_abn->{$sample}{"Type"}}),"\t",join(",",@{$asample_abn->{$sample}{"Value"}}),"\n";
	}
	close (AB);
}

sub abnormal_recognize {#
	my ($adc, $dir, $aabnormal, $type, $threshold, $cmp) = @_;
	my ($file, $table_direct, $index);
	if ($type eq "LowReads") {
		$file = "$dir/01.Uniq.stat";
		$table_direct = "vertical";
		$index = 1;  ## info index(column or row index) in table
	}

	if ($type eq "LowDepth") {
		$file = "$dir/05.Hotspot.stat";
		$table_direct = "horizon";
		$index = 1;  ## info index(column or row index) in table
	}

	open (I,$file) or die $!;
	if ($table_direct eq "vertical") {
		while (<I>) {
			chomp;
			next if(/^$/ || /Sample/);
			my ($sample,@info)=split;
			if (($cmp eq "Low" && $info[$index-1] < $threshold) || ($cmp eq "High" && $info[$index-1] > $threshold)) {
				push @{$aabnormal->{$sample}->{"Type"}}, $type;
				push @{$aabnormal->{$sample}->{"Value"}}, $info[$index-1];
			}
		}
	}else{
		my $head = <I>;
		chomp $head;
		my (undef, @sample)= split /\t/, $head;
		my @info;
		if ($index==1) {
			my $info = <I>;
			chomp $info;
			(undef, @info)=split /\t/, $info;
		}elsif($index == -1){
			my $info = `tail -1 $file`;
			chomp $info;
			(undef, @info)=split /\t/, $info;
		}else{
			print "Wrong index in $file!\n";
			die;
		}

		for (my $i=0; $i<@sample ; $i++) {
			if (($cmp eq "Low" && $info[$i] < $threshold) || ($cmp eq "High" && $info[$i] > $threshold)) {
				push @{$aabnormal->{$sample[$i]}->{"Type"}}, $type;
				push @{$aabnormal->{$sample[$i]}->{"Value"}}, $info[$i];
			}
		}
	}
	close (I) ;

}

sub statistic {#
	my ($dir, $dir_statistic) = @_;
	&Run("perl $Bin/merge_stat_result.pl -id $dir/01.fastq_uniq/ --Uniq_QC -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_stat_result.pl -id $dir/02.barcode_process/ --Bar_QC -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_stat_result.pl -id $dir/03.data_process/ --Primer_QC -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_stat_result.pl -id $dir/04.consensus_make/ --Map_QC -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_stat_result.pl -id $dir/04.consensus_make/ --Consens_Stat -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_stat_result.pl -id $dir/05.variant_detect/ --HotSpot_Stat -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_stat_result.pl -id $dir/05.variant_detect/ --Variant_Known -od $dir_statistic", $sh);
#	&Run("perl $Bin/variants_known_result_stat.pl -i $dir_statistic/05.Variant_known.result -k 05.Variant_known.result -od $dir_statistic", $sh);
	&Run("perl $Bin/merge_total_statistics.pl -id $dir -k Total -od $dir_statistic", $sh);
	
	## genotype result
	&Run("cp $dir/06.genotyping/Total.genotype.result $dir_statistic", $sh) if(-e "$dir/06.genotyping/Total.genotype.result");
	&Run("cp $dir/06.genotyping/cffdna.txt $dir_statistic/Total.cffdna.txt", $sh) if(-e "$dir/06.genotyping/cffdna.txt");
	my $dir_result = "$dir_statistic/06.genotype_result/";
	`mkdir $dir_result` unless(-d $dir_result);
	&Run("cp $dir/06.genotyping/*.genotype.txt $dir_result/", $sh) if(defined glob("$dir/06.genotyping/*.genotype.txt"));
}

sub detect {#
	my ($adc, $fdata_config, $indir, $outdir, $step) = @_;
	open (SH, ">$outdir/detect.sh") or die $!;
	foreach my $sample (keys %{$adc}) {
		my $cmd = "perl $Bin/cfBEST_pipeline_single.pl -i $fdata_config -ir $ref -ip $fpanel -ib $fbarcode -cid $configID -s $sample -indir $indir -min_depth $min_depth -min_CV $min_CV -mismatch_bar1 $mismatch_bar1 -mismatch_bar2 $mismatch_bar2 -threads $threads -step $step -od $outdir/ -distance $max_size";
		if (defined $SingleEnd) {
			$cmd .= " --SingleEnd -secBar_len $secBar_len";
		}
		$cmd .= " >$log_dir/$sample.log 2>&1";

		print SH $cmd,"\n";
	}

	&Run("parallel -j $num_parallel < $outdir/detect.sh", $sh);
}


sub output_sample_description {#
	my ($adc, $dir) = @_;
	open (O,">$dir/00.Sample.des") or die $!;
	print O "SampleID\tIndex\tDescription\n";
	foreach my $sample (sort {$a cmp $b} keys %{$adc}) {
		my $des = defined $adc->{$sample}->{"sample_des"}? $adc->{$sample}->{"sample_des"}: "No";
		print O $sample,"\t", $adc->{$sample}->{"index"},"\t",$des,"\n";
	}
	close (O);
}

sub GetTime {
	my ($sec, $min, $hour, $day, $mon, $year, $wday, $yday, $isdst)=localtime(time());
	return sprintf("%4d-%02d-%02d %02d:%02d:%02d", $year+1900, $mon+1, $day, $hour, $min, $sec);
}

sub check_continuous_mutation{  
	my $f=shift;
	`rm $f` if (-e $f);
	open CM,">$f";
	print CM "SampleID\tchr\tstart\tend\n";
	close CM;
}


sub USAGE {#
	my $usage=<<"USAGE";
Program:
Version: $version
Contact:zeng huaping<huaping.zeng\@genetalks.com> 

Usage:
  Options:
  -ss       <file>    Input sample sheet file, requried
  -id       <str>     config ID in panel config file needed, requried
  -indir    <dir>     rawdata dir, "Undetermined_*_001.fastq.gz", or "L1/*.R1.fastq.gz", requried
  -pc       <file>    Input panel config file, [$fpanel]
  -bc       <file>    Input barcode config file, [$fbarcode]
  -ref      <file>    Input ref genome file, [$ref]
  -outdir   <dir>     outdir of output file, [./]

  --SingleEnd         SingleEnd, read2 as second barcode, optional
  --Double_Barcode    Double barcode, optional
  --Abnormal_Recognize   abnormal sample recognize, optional
  -min_depth     <int>    min group depth, [4]
  -min_CV        <float>  min CV, [0.65]
  -mdepth_snp    <int>	  min depth of snp to infer cffDNA, [$min_depth_snp]
  -msize         <int>    max intersize between read1 and read2,[$max_size]
  -secBar_len    <int>    length of r2 seq as barcode when specified --SingleEnd, [9] 
  -mismatch_bar1 <int>    mismatch of the first barcode, [1]
  -mismatch_bar2 <int>    mismatch of the second barcode, [1]
  -parallel      <int>    jobs num of parallel, [4]
  -threads       <int>    threads num, [6]
  -step          <int>    step, [1]
  	0: call data from Undetermined
	1: data uniq
	2: barcode process
	3: data process
	4: consensus maker
	5: variants detect
	6: genotyping
	7: merge statistic and abnormal sample recognize

  -h         Help

USAGE
	print $usage;
	exit;
}
