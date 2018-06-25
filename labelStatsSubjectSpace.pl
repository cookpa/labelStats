#!/usr/bin/perl -w

use strict;
use Getopt::Long;

my $usage = qq{

  $0 
    --image grayImage.nii.gz grayImage2.nii.gz | --image-list grayImages.txt 
    --label-image labelImage1.nii.gz labelImage2.nii.gz | --label-image-list labelImages.txt
    --label-def labelDefinition.csv
    --output-root myStats 
    [ options ]

  Uses c3d to compute statistics in grayscale images over labeled regions, and output them as 
  CSV files.
 
  Each image has its own labels, and the images need not be aligned. However, there must be 
  a common definition of the labels, ie label N must be the same thing in each image.

  Some labels might not exist in all images, in which case NAs are produced.

  To avoid problems with NIFTI header precision in ITK, the transform from each gray image is copied 
  to the corresponding label image at run time. The image on disk is not modified. Therefore
  there will be no warning if the images are not aligned - the user must ensure that each label
  image is in the same space as the gray image.


  Required args:

    --image
      Image file name(s). The images must be co-registered to a common space (the template).

    --image-list
      Overrides --image. Argument should be a text file containing images to process, one per line.

    --label-image 
      An image containing positive integer labels. Only labels present in the label definition
      file will appear as columns in the output. These must be specified in the same order 
      as the gray images.

    --label-image-list
      Argument should be a text file containing label images, one per line. The order must match
      the order

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

    CSV files containing the grayscale mean, sd, max, min, within each label, and the voxel count
    and volume of the labels themselves.

    If a label does not exist in a particular image, NAs are generated.

    The extent (in voxels) and volume (in mm^3) of each ROI is output to a separate file if requested.


  Requires c3d
};

# Required with no default
my ($labelDefFile, $outputRoot);

# Also required but may be populated in different ways
my @labelImages = ();
my @grayImages = ();

# List in a text file
my $grayImageList = "";
my $labelImageList = "";

# Scale the gray images by this, used to help preserve precision
my $scale = 1;

if (!($#ARGV + 1)) {
    print "$usage\n";
    exit 1;
}

GetOptions ("image=s{1,10000}" => \@grayImages,
            "image-list=s" => \$grayImageList,
            "label-image=s{1,10000}" => \@labelImages,
            "label-image-list=s" => \$labelImageList,
	    "label-def=s" => \$labelDefFile,
	    "output-root=s" => \$outputRoot,
	    "scale=f" => \$scale
    )
    or die("Error in command line arguments\n");


my @statNames = ("Mean", "SD", "Max", "Min", "Count", "VolumeMM3");
my @statIndices = (2, 3, 4, 5, 6, 7);

my $numStats = scalar(@statIndices);

# Get list of labels from CSV file. These labels will be searched for in all subject images
# Other labels in individual label files are ignored
my @labelDefLines = ();

open (FH, "< $labelDefFile") or die "Can't open $labelDefFile for read: $!";

@labelDefLines = <FH>;

close (FH);

# Ditch header
shift @labelDefLines;

# Label IDs are a hash because they might not be ordered or even contiguous, and 
# the set of labels may differ in subjects (eg if one label has zero volume)
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

# check we have some input, either from a list or directly
if (scalar(@grayImages) == 0) {
    print "  No input images specified \n";
    exit 1;
}  

# Same thing for labels
if (-f $labelImageList) {
    open (FH, "< $labelImageList") or die "Can't open $labelImageList for read: $!";
    @labelImages = <FH>;
    close FH;
    chomp @labelImages;
}

if (scalar(@labelImages) == 0) {
    print "  No label images specified \n";
    exit 1;
} 

my $outputHeader = "Image,LabelImage," . join(",", @labelDef{@orderedLabelIDs}) . "\n";

# Initialize output files
my @outputFiles = ();

for (my $i = 0; $i < $numStats; $i++) {
    local *FILE;
    open(FILE, ">${outputRoot}$statNames[$i].csv") || die "Can't open output files";
    push(@outputFiles, *FILE);
}

for (my $i = 0; $i < $numStats; $i++) {
    print {$outputFiles[$i]} $outputHeader;
}

print "\n\n";

for (my $imageCounter = 0; $imageCounter < scalar(@grayImages); $imageCounter++) {

    my $image = $grayImages[$imageCounter];
    my $labelImage = $labelImages[$imageCounter];

    print "  Processing $image $labelImage\n"; 

    my @subjectLabelLines = ();

    if ($image eq "NA" || $labelImage eq "NA") {
	@subjectLabelLines = ("DummyHeader");
    }
    else {
	@subjectLabelLines = `c3d $image -scale $scale -dup $labelImage -copy-transform -lstat`;
    }

    # Header line
    shift @subjectLabelLines;
    
    # Hash of info for labels that exist in this subject
    my %subjectLabelTokens = ();

    foreach my $line (@subjectLabelLines) { 

	my @tokens = split('\s+', $line);
	
	$subjectLabelTokens{$tokens[1]} = \@tokens; 
	
    }

    # Line of output to be created by inserting values for each label
    my @statLines = ();

    for (my $i = 0; $i < $numStats; $i++) { 
	$statLines[$i] = "$image,$labelImage";   
    }

    foreach my $label (@orderedLabelIDs) { 
	
	# retrieve label info for this label
	my @labelTokens = ();

	if ( exists $subjectLabelTokens{$label} ) {
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
