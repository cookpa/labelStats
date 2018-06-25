#!/usr/bin/perl -w

use strict;
use Getopt::Long;

my $usage = qq{

  $0 
    --image grayImage.nii.gz grayImage2.nii.gz | --image-list grayImages.txt 
    --label-image templateLabels.nii.gz 
    --label-def labelDefinition.csv
    --output-root myStats 
    [ options ]

  Uses c3d to compute statistics in grayscale images over labeled regions, and output them as 
  CSV files.
 
  All images must exist in a common space with identical voxel and physical extents.


  Required args:

    --image
      Image file name(s). The images must be co-registered to a common space (the template).

    --image-list
      Overrides --image. Argument should be a text file containing images to process, one per line.

    --label-image 
      An image containing positive integer labels. Only labels present in the label definition
      file will appear as columns in the output.

    --label-def 
      A CSV file containing label definitions, in the format

         LabelId,LabelName
         0,clear
         1,someLabel
         2,someOtherLabel

       It's not necessary to define every label in the image, but statistics are only output
       for defined labels.
 
    --output-root
      Root for output files.

  Options:

    --scale 
      A scaling factor applied to the input images before statistics are computed. This is sometimes 
      needed to overcome limitations in the precision of c3d's text output. 

      For example, if an ROI has a mean diffusivity of 7.8489E-4 mm^2 / s, c3d will write this as 
      0.00078. More precision can be preserved by scaling by 1000, and recording 0.78489 mm^2 / ms.

      The original data is not modified by this option.

    --output-label-vols
      Optionally compute the label volumes.

  Output:

    CSV files containing the mean, sd, max and min of each input image in each defined label.

    The extent (in voxels) and volume (in mm^3) of each ROI is output to a separate file if requested.


  Requires c3d
};

my ($labelImage, $labelDefFile, $outputRoot);

my @grayImages = ();

my $computeLabelVols = 0;

# List in a text file
my $grayImageList = "";

my $scale = 1;

if (!($#ARGV + 1)) {
    print "$usage\n";
    exit 1;
}

GetOptions ("image=s{1,10000}" => \@grayImages,
            "image-list=s" => \$grayImageList,
            "label-image=s" => \$labelImage,
	    "label-def=s" => \$labelDefFile,
	    "output-root=s" => \$outputRoot,
	    "scale=f" => \$scale,
	    "output-label-vols=i" => \$computeLabelVols
    )
    or die("Error in command line arguments\n");

my @statNames = ("Mean", "SD", "Max", "Min");

# Column indices from c3d
# Because of leading white space, these are indexed from 1
# ie label ID is column 1, not 0, mean is 2, etc
my @statIndices = (2, 3, 4, 5);

my $numStats = scalar(@statIndices);

# Get list of labels from CSV file. These labels will be searched for in all subject images
# Other labels in individual label files are ignored
my @labelDefLines = ();

open (FH, "< $labelDefFile") or die "Can't open $labelDefFile for read: $!";

@labelDefLines = <FH>;

close (FH);

# Ditch header
shift @labelDefLines;

# Label IDs are a hash because they might not be ordered
my %labelDef = ();

foreach my $line (@labelDefLines) {

    chomp $line;

    my @tokens = split(',', $line);

    $labelDef{$tokens[0]} = $tokens[1];

}

# When we read the images, we iterate over an ordered list of labels by label ID
my @orderedLabelIDs = sort {$a <=> $b} keys(%labelDef);

# Print information for debug purposes
my $numLabels = scalar(@orderedLabelIDs);

print "\n  Computing label indices on $numLabels labels:\n\n";

foreach my $key (@orderedLabelIDs) {
    print "  $key\t$labelDef{$key}\n";
}

# read list of grayscale images if we have one
if (-f $grayImageList) {
    open (FH, "< $grayImageList") or die "Can't open $grayImageList for read: $!";
    @grayImages = <FH>;
    close FH;
    chomp @grayImages;
}

# check we have some input
if (scalar(@grayImages) == 0) {
    print "  No input images specified \n";
    exit 1;
}  

# Initialize output
my @outputFiles = ();

for (my $i = 0; $i < $numStats; $i++) {
    local *FILE;
    open(FILE, ">${outputRoot}$statNames[$i].csv") || die "Can't open output files";
    push(@outputFiles, *FILE);
}

my $outputHeader = "Image," . join(",", @labelDef{@orderedLabelIDs}) . "\n";

for (my $i = 0; $i < $numStats; $i++) {
    print {$outputFiles[$i]} $outputHeader;
}

print "\n\n";

for (my $imageCounter = 0; $imageCounter < scalar(@grayImages); $imageCounter++) {
    
    my $image = $grayImages[$imageCounter];
    
    print "  Processing $image\n"; 
    
    my @subjectLabelLines = `c3d $image -scale $scale $labelImage -lstat`;
    
    # Header line
    shift @subjectLabelLines;
    
    # Hash of info for labels 
    my %subjectLabelTokens = ();
    
    foreach my $line (@subjectLabelLines) { 
	
	my @tokens = split('\s+', $line);
	
	$subjectLabelTokens{$tokens[1]} = \@tokens; 
	
    }
    
    # Line of output to be created by inserting values for each label
    my @statLines = ();
    
    for (my $i = 0; $i < $numStats; $i++) { 
	$statLines[$i] = "$image";   
    }
    
    foreach my $label (@orderedLabelIDs) { 
	
	my @labelTokens;
	
	# retrieve label info for this label
	if ( exists($subjectLabelTokens{$label}) ) {
	    @labelTokens = @{$subjectLabelTokens{$label}};
	}
	else {
	    @labelTokens = (("NA") x 8);
	}
	
	for (my $i = 0; $i < $numStats; $i++) {
	    $statLines[$i] .= ",$labelTokens[$statIndices[$i]]";	
	}
	
    }
    
    for (my $i = 0; $i < $numStats; $i++) { 
	print {$outputFiles[$i]} $statLines[$i] . "\n";
    }
    
}

for (my $i = 0; $i < $numStats; $i++) {
    close $outputFiles[$i];
}


# Now get the label statistics if desired

if ($computeLabelVols) {

    print "Processing $labelImage\n"; 

    @outputFiles = ();

    @statNames = ("Count", "VolumeMM3");

    @statIndices = (6, 7);

    $numStats = scalar(@statIndices);
    
    for (my $i = 0; $i < $numStats; $i++) {
	local *FILE;
	open(FILE, ">${outputRoot}LabelImage${statNames[$i]}.csv") || die "Can't open output files";
	push(@outputFiles, *FILE);
    }

    for (my $i = 0; $i < $numStats; $i++) {
	print {$outputFiles[$i]} $outputHeader;
    }
    
    my @labelLines = `c3d $labelImage -dup -lstat`;
    
    # Header line
    shift @labelLines;
    
    # Hash of info for labels 
    my %labelTokens = ();
    
    foreach my $line (@labelLines) { 
	
	my @tokens = split('\s+', $line);

	$labelTokens{$tokens[1]} = \@tokens; 
	
    }
    
    # Line of output to be created by inserting values for each label
    my @statLines = ();
    
    for (my $i = 0; $i < $numStats; $i++) { 
	$statLines[$i] = "$labelImage";   
    }
    
    foreach my $label (@orderedLabelIDs) { 
	my @currentLabelTokens;
	
	if ( exists($labelTokens{$label}) ) {
	    @currentLabelTokens = @{$labelTokens{$label}}; 
	}
	else {
	    @currentLabelTokens = (("NA") x 8);
	}

	for (my $i = 0; $i < $numStats; $i++) {
	    $statLines[$i] .= ",$currentLabelTokens[$statIndices[$i]]";	
	}
    }
    
    for (my $i = 0; $i < $numStats; $i++) { 
	print {$outputFiles[$i]} $statLines[$i] . "\n";
    }
    

    for (my $i = 0; $i < $numStats; $i++) {
	close $outputFiles[$i];
    }

}
