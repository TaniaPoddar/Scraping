use strict;
use warnings;
use TryCatch;
#Installing TryCatch => ppm install TryCatch
use LWP::Simple;
use JSON;
use Data::Dumper;
#Installing DateTime => ppm install DateTime
use DateTime;
use URI::Escape;
#Installing Text::CSV=> ppm install Text-CSV
use Text::CSV;

#Sub-routines ----------------------------------------------------------------------------------------
#Get city dictionary from auto-suggest module 
sub getAutoCompleteString {
    my $time = getUnixTimeStamp();
	my $city = $_[0]; #Contains city text for auto-suggest		
	my $autoSuggestUrl = "http://www.makemytrip.com/mi8/core/?&st=hotel&t=3"."&cc=".$city."_0_cityName_%23to_H&id=%23to"."&term=".$city."&s=0&o=50&mr=true"."&_=".$time;
	my $res = get $autoSuggestUrl;
	die "Could not get Auto-suggest URL : $autoSuggestUrl!" unless defined $res;
	
	#parse JSON response and return city dictionary	
	my $decoded = decode_json($res);	
	#print Dumper($decoded);	
	return $decoded->{"response"}{"docs"}[1];		
}

sub getUnixTimeStamp {
	return time;
}

sub getCityData {	
	my $todaysDate = DateTime->now;	
	my $checkin = $todaysDate->add(days => int($_[1]))->strftime('%m%d%Y'); #Adding seed days to today's date
	my $checkout = $todaysDate->add(days => (int($_[1])+int($_[2])))->strftime('%m%d%Y'); #Adding seed days + nights of stay to today's date
	my $adults = $_[3];
	my $children = $_[4];
	my $session_cid = "";
	
	#Prepare URL for MMT Hotels Listing Page  
	my $base_url_mmt = "http://hotelz.makemytrip.com/makemytrip/site/hotels/";
	
	#$_[0] => city dictionary
	my $country = $_[0]->{"country_code"}; 	
	my $searchText = $_[0]->{"value"};	
	$searchText =~ s/^\s*(\S*(?:\s+\S+)*)\s*$/$1/; #Removing leading and trailing spaces
	$searchText =~ s/ /+/g; #Replace all spaces by + for url query format
	$searchText = uri_escape($searchText); #encoding spaces		
	my $roomStayQualifier = int($adults)."e".int($children)."e";
	my $city = $_[0]->{"hotel"};
	my $area = "null";	
	
	#Building URL to fetch session_cid from html of page
	my $queryString = "search"."?checkin=".$checkin."&checkout=".$checkout."&country=".$country."&searchText=".$searchText."&roomStayQualifier=".$roomStayQualifier."&city=".$city."&area=".$area;	
	my $final_url = $base_url_mmt.$queryString; 
	my $res = get $final_url;
	
	if( $res =~ m/"session_cid" name="session_cId" value="(.*?)" type="hidden"/ )
	{
		$session_cid = $1;	
	}
		
	#Building URL to fetch Hotels Listing HTML	
	my $numPages = 1;        
	$queryString = "search/searchWithJson"."?checkin=".$checkin."&country=".$country."&searchText=".$searchText."&roomStayQualifier=".$roomStayQualifier."&city=".$city."&checkout=".$checkout."&area=".$area."&session_cId=".$session_cid."&ajaxCall=T";                                                           	
		
	$final_url = $base_url_mmt.$queryString;	
	$res = get $final_url;
	my $jsondecoded = decode_json($res)->{"searchResponseDTO"}; 	
	my $hotelsList = $jsondecoded->{"hotelsList"}; #List of hotels from page 1
	my $hotelsData = parseJSON($hotelsList, $searchText, $checkin, $checkout, $roomStayQualifier);
	#put this parsed hotelsData into a Data Structure and return 
	my $pageLimit = int($jsondecoded->{"pagination"}{"limit"});
	my $totalHotels = int($jsondecoded->{"totalHotelsCount"});
	$numPages = $totalHotels/$pageLimit + ($totalHotels%$pageLimit ? 1 : 0);

	my $pgNum = 2;
	while ($pgNum <= $numPages) {						
		$queryString = "search/page"."?session_cId=".$session_cid."&pageNum=".$pgNum."&city=".$city."&country=".$country."&checkin=".$checkin."&checkout=".$checkout."&searchText=".$searchText."&region=&area="."&roomStayQualifier=".$roomStayQualifier;
		$final_url = $base_url_mmt.$queryString;					
		$res = get $final_url;
		$jsondecoded = decode_json($res);
		$hotelsList = $jsondecoded->{"hotelsList"}; #List of hotels from page 2 onwards
		parseJSON($hotelsList, $searchText, $checkin, $checkout, $roomStayQualifier);		
		$pgNum ++;				
		#last;
	}
	return ;
}	

sub parseJSON {	
	my $hotelsList = $_[0];		
	#############################
	foreach my $hotel (@$hotelsList) { 		
		my $hotelName = $hotel->{"name"};
		my $hotelID = $hotel->{"id"};
		my $address = $hotel->{"address"}{"line1"}.", ".$hotel->{"address"}{"line2"}.", ".$hotel->{"address"}{"city"}.", ".$hotel->{"address"}{"country"};
		my $pah = $hotel->{"isPAHAvailable"}; #Is pay at hotel available ?
		my $hotelRating = $hotel->{"htlAvgRating"};
		my $promotionsCount = int($hotel->{"promotions"}{"promotionsCount"});
		my $city = $hotel->{"address"}{"city"};
		my @promotions = ();				
		for (my $j=0;$j<$promotionsCount;$j++){
			my $promotion = $hotel->{"promotions"}{"promotionsList"}[$j]{"value"};			
			push(@promotions, $promotion);						
		}
		my $hotelPricePerRoomPerNight = $hotel->{"displayFare"}{"slashedPrice"}{"value"};	
		my $starRating = $hotel->{"starRating"}{"value"};
		#Convert promotions array to string
		my $promotionsString = join(' | ', @promotions);
		
		insertIntoCSV($hotelID, $hotelName, $city, $address, $hotelPricePerRoomPerNight, $hotelRating, $starRating, $promotionsString, $pah);		
		#last;
	}	
	return ;
}

sub insertIntoCSV {	
	my $csv = Text::CSV->new({ binary => 1, eol => $/ });	
	$csv->column_names('Website', 'Hotel_ID', 'Hotel_Name', 'City', 'Address', 'Per_Room_Per_Night', 'Hotel_Rating', 'Star_Rating', 'Promotions', 'Pay_@_Hotel');
	open my $fh, ">>", "mmt_hotels_listing_scrape.csv" or die "new.csv: $!";
		
	$csv->print ($fh, ['MMT', $_[0], $_[1], $_[2], $_[3], $_[4], $_[5], $_[6], $_[7], $_[8]]);	
	close $fh or die "$!";
}


#Main--------------------------------------------------------------------------------------------------
#Console input
print "Crawlmaster v1.0 (Beta)\n";
print "Please enter number of days from today (check-in):\n";
print "Seed Days = ";
my $seedDays = <>;
print "\nPlease enter number of nights of stay:\n";
print "Nights = ";
my $numNights = <>;
print "\nPlease enter number of adults:\n";
print "Adults = ";
my $adults = <>;
print "\nPlease enter number of children:\n";
print "Children = ";
my $children = <>;

my %cityList = (
		0, 'Delhi',
		1, 'Bengaluru',
		2, 'Mumbai',
		3, 'Goa',
		4, 'Gurgaon',
		5, 'Hyderabad',
		6, 'Chennai',
		7, 'Jaipur',
		8, 'Pune',
		9, 'Kolkata',
		10, 'Amritsar'
		);

foreach my $i (sort { $a <=> $b } keys(%cityList)) { #Sort city indexes		
	my $cityJsonRes = getAutoCompleteString($cityList{$i});	
	getCityData($cityJsonRes, $seedDays, $numNights, $adults, $children);		
	#last;
}