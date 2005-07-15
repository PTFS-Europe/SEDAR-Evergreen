#!/usr/bin/perl
use strict; use warnings;
use Data::Dumper; 
use OpenILS::Utils::Fieldmapper;  

my $map = $Fieldmapper::fieldmap;

# if a true value is provided, we generate the web (light) version of the fieldmapper
my $web = $ARGV[0];
# List of classes needed by the opac
my @web_hints = qw/ex mvr au aou aout asv asva asvr asvq 
		circ acp acpl acn ccs perm_ex ahn ahr aua ac 
		actscecm crcd crmf crrf mus mbts/;

print <<JS;

//  ----------------------------------------------------------------
// Autogenerated by fieldmapper.pl
// Requires JSON.js
//  ----------------------------------------------------------------

function Fieldmapper() {}

Fieldmapper.prototype.clone = function() {
	var obj = new this.constructor();

	for( var i in this.a ) {
		var thing = this.a[i];
		if(thing == null) continue;

		if( thing._isfieldmapper ) {
			obj.a[i] = thing.clone();
		} else {

			if(instanceOf(thing, Array)) {
				obj.a[i] = new Array();

				for( var j in thing ) {

					if( thing[j]._isfieldmapper )
						obj.a[i][j] = thing[j].clone();
					else
						obj.a[i][j] = thing[j];
				}
			} else {
				obj.a[i] = thing;
			}
		}
	}
	return obj;
}



function FieldmapperException(message) {
	this.message = message;
}

FieldmapperException.toString = function() {
	return "FieldmapperException: " + this.message + "\\n";

}


JS

for my $object (keys %$map) {

	if($web) {
		my $hint = $map->{$object}->{hint};
		next unless (grep { $_ eq $hint } @web_hints );
		#next unless( $hint eq "mvr" or $hint eq "aou" or $hint eq "aout" );
	}

my $short_name = $map->{$object}->{hint};

print	<<JS;
$short_name.prototype					= new Fieldmapper();
$short_name.prototype.constructor	= $short_name;
$short_name.baseClass					= Fieldmapper.constructor;

function $short_name(a) {
	this.classname = "$short_name";
	this._isfieldmapper = true;
	if(a) { 
		if( a.constructor == Array) 
			this.a = a;  
		else
			throw new FieldmapperException(
				"Attempt to build fieldmapper object with non-array");
	} else this.a = [];
}

$short_name._isfieldmapper = true;
JS

for my $field (keys %{$map->{$object}->{fields}}) {

my $position = $map->{$object}->{fields}->{$field}->{position};

print <<JS;
$short_name.prototype.$field = function(n) {if(arguments.length == 1) this.a[$position] = n; return this.a[$position]; }
JS

}
}

