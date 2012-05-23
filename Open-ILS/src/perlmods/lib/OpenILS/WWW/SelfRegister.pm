package OpenILS::WWW::SelfRegister;

# Copyright (C) 2011 Mark Gavillet and PTFS-Europe
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

use strict; use warnings;

use Apache2::Log;
use Apache2::Const -compile => qw(OK REDIRECT DECLINED NOT_FOUND :log);
use APR::Const    -compile => qw(:error SUCCESS);
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::RequestUtil;
use CGI;
use Template;

use OpenSRF::EX qw(:try);
use OpenSRF::Utils qw/:datetime/;
use OpenSRF::Utils::Cache;
use OpenSRF::System;
use OpenSRF::AppSession;

use OpenILS::Utils::Fieldmapper;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Application::AppUtils;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use Digest::MD5 qw(md5_hex);
use Time::localtime;
use Time::Local;

my $log = 'OpenSRF::Utils::Logger';
my $U = 'OpenILS::Application::AppUtils';

my ($bootstrap, $actor, $templates);
my $i18n = {};
my $init_done = 0; # has child_init been called?

sub import {
    my $self = shift;
    $bootstrap = shift;
}

sub child_init {
    OpenSRF::System->bootstrap_client( config_file => $bootstrap );
    
    my $conf = OpenSRF::Utils::SettingsClient->new();
    my $idl = $conf->config_value("IDL");
    Fieldmapper->import(IDL => $idl);
    $templates = $conf->config_value("dirs", "templates");
    $actor = OpenSRF::AppSession->create('open-ils.actor');
    load_i18n();
    $init_done = 1;
}

sub self_register {
    my $apache = shift;

    child_init() unless $init_done;

    return Apache2::Const::DECLINED if (-e $apache->filename);

    $apache->content_type('text/html');

	my $cgi = new CGI;
    my $ctx = {};

    $ctx->{'uri'} = $apache->uri;

    my $tt = Template->new({
        INCLUDE_PATH => $templates
    }) || die "$Template::ERROR\n";

	my $mode=$cgi->param('mode');
	
    if ($mode ne 'create') {
        show_form($apache, $cgi, $tt, $ctx);
    } else {
    	create_borrower($apache,$cgi,$tt,$ctx);
    }
}

sub create_borrower {
	my ($apache,$cgi,$tt,$ctx)=@_;
	my $barcode=generate_barcode();
	
	my $bor		=	new Fieldmapper::actor::user ();
	my $addr	=	new Fieldmapper::actor::user_address ();
	my $card	=	new Fieldmapper::actor::card ();
	
	$addr->street1($cgi->param('street1'));
	$addr->street2($cgi->param('street2'));
	$addr->city($cgi->param('city'));
	$addr->county($cgi->param('county'));
	$addr->post_code($cgi->param('postcode'));
	$addr->isnew(1);
	$addr->valid('t');
	$addr->within_city_limits('t');
	$addr->address_type('MAILING');
	my $country;
	if ($cgi->param('country'))
	{
		$country=$cgi->param('country');
	}
	else
	{
		$country='UK';
	}
	$addr->country($country);
	$addr->state($country);
	$addr->pending('f');
		
	$card->barcode($barcode);
	$card->isnew(1);
	
	$bor->first_given_name($cgi->param('fname'));
	$bor->second_given_name($cgi->param('mname'));
	$bor->family_name($cgi->param('surname'));
	$bor->usrname($barcode);
	$bor->passwd('xxxxx');				# Hard coded default password to be changed by the user
	$bor->day_phone($cgi->param('dphone'));
	$bor->evening_phone($cgi->param('ephone'));
	$bor->other_phone($cgi->param('ophone'));
	$bor->email($cgi->param('email'));
	$bor->home_ou($cgi->param('library'));
	my $dob_d=sprintf("%2d",$cgi->param('dob_d'));
	$dob_d=~tr/ /0/;
	my $dob_m=sprintf("%2d",$cgi->param('dob_m'));
	$dob_m=~tr/ /0/;
	my $dob=$cgi->param('dob_y')."-".$dob_m."-".$dob_d."T00:00:00+0000";
	$bor->dob($dob);
	$bor->addresses([$addr]);
	$bor->cards([$card]);
	$bor->isnew(1);
	$bor->ident_type(3);
	$bor->profile(xx);					# Set to id of entry in permission.grp_tree
	$bor->expire_date(get_expiry());
	my $age=get_age($dob_d,$dob_m,$cgi->param('dob_y'));
	if ($age>15)
	{
		$bor->juvenile('f');
	}
	else
	{
		$bor->juvenile('t');
	}
	
	my $auth=login('<user>','<password>');	# Set to user and password of user with permissions to create a new patron
	
	my $newbor=$U->simple_scalar_request(
		"open-ils.actor",
		"open-ils.actor.patron.update",
		$auth,
		$bor,
	);
	
	### message below contains:
	# default password specified in line 132
	# URL of OPAC login screen (e.g. https://prd1.sedar.org.uk/opac/en-GB/skin/stirling/xml/myopac.xml?d=0)
	my $message='Your new library account has been successfully created. Your login details are:

Username: '.$barcode.'
Password: xxxxx

The first time you log into the catalogue you will be prompted to change your password. To log into the catalogue, go to <url_of_opac_login_screen>

After creating your new password, please bring one form of identification to the library on your first visit to confirm your membership. 
Some of the ID documents that can be used are:

		* Driving licence
		* Council tax payment form
		* Rent book
		* A recent electricity, gas or telephone bill
		* Any addressed item which has been received through the post

You will then be issued with a library card which can be used straight away. 
If you do not collect your library card within two months, your account will be deactivated.';
	sendMail($cgi->param('email'),'<library_email>','<library_name> account confirmation',$message);	# Specify the library email address and name
	$message='An online account was created by the following user:

Name:		'.$cgi->param('fname').' '.$cgi->param('surname').'
Barcode: 	'.$barcode;
	sendMail('<to_email_address>','<from_email_address>','<library_name> account creation',$message);	# Specify the to and from addresses, and the Library name
	sub sendMail {
		my ($to,$from,$subject,$message)=@_;
		open(MAIL,"| /usr/lib/sendmail -t");
		print MAIL "From: $from\n";
		print MAIL "To: $to\n";
		print MAIL "Subject: $subject\n\n";
		print MAIL "$message\n";
		close (MAIL);
	}
	
	$ctx->{'barcode'}=$newbor->cards->[0]->barcode;
	$tt->process('self_registration/self_reg_confirm.tt2',$ctx)
		|| die $tt->error();
	return Apache2::Const::OK;
}

sub get_age
{
	my ($d,$m,$y)=@_;
	my $secs  = 24 * 60 * 60;
	my $days = 365;
	my $dob_time = timelocal(0, 0, 0, $d, ($m-1), $y);
	my $age      = time() - $dob_time;
	$age      = int($age/$secs);
	$age      = int($age/$days);
	return $age;
}

sub get_expiry
{
	my $tm=localtime;
	my $time = timelocal($tm->sec, $tm->min, $tm->hour, $tm->mday, $tm->mon, $tm->year+1900);
	$time = $time + 8 * 7 * 24 * 60 * 60;
	$tm = localtime($time);
	my $exp_d=sprintf("%2d",$tm->mday);
	$exp_d=~tr/ /0/;
	my $exp_m=sprintf("%2d",$tm->mon+1);
	$exp_m=~tr/ /0/;
	my $exp_y=sprintf("%04d",$tm->year+1900);
	my $expiry=$exp_y."-".$exp_m."-".$exp_d."T00:00:00+0000";
	return $expiry;
}

sub login {
	my( $username, $password ) = @_;
	my $seed = $U->simple_scalar_request(
		'open-ils.auth',
		'open-ils.auth.authenticate.init', $username );
	die "No auth seed returned\n" unless $seed;
	my $response = $U->simple_scalar_request(
			'open-ils.auth',
			'open-ils.auth.authenticate.complete',
			{
				username => $username,
				password => md5_hex($seed . md5_hex($password)),
				type            => 'opac',
			}
		);
	die "No login response returned\n" unless $response;
	my $key = $response->{payload}->{authtoken};
	die "Login failed\n" unless $key;
	return $key;
}

sub get_sedar_branch_list {
	my $branch_list;
	return $branch_list = 
		$U->simple_scalar_request(
			"open-ils.cstore",
			"open-ils.cstore.direct.actor.org_unit.search.atomic",
			{ 
				ou_type => 3,
			},
			{
				order_by			=> { aou => 'name'},
				select			=> { aou => ["id","shortname", "name"]},
			}
		);
}

sub show_form {
	my ($apache, $cgi, $tt, $ctx) = @_;
    my $branch_list=get_sedar_branch_list();
    #my $branch_list=get_branch_list();
    $ctx->{'branch_list'}=$branch_list;
	$tt->process('self_registration/self_reg_form.tt2', $ctx)
            || die $tt->error();
        return Apache2::Const::OK;
}

sub get_last_barcode {
	my $last_id;
	my $stem="28048";	# Set the initial 5 digits of the library barcode
	return $last_id=
		$U->simple_scalar_request(
			"open-ils.cstore",
			"open-ils.cstore.direct.actor.user.search",
			{
				id	=>	{">" => 1},
			}
			,
			{
				limit	=>	1,
				order_by			=> { au => 'id desc'},
				select			=> { au => ["id"]},
			}
		);
}

sub generate_barcode {
	my $barcode;
	my $barcode_type='2';		# institution
	my $authority='8048';		# Stirling
	my $id=get_last_barcode();
	$id=($id->id)+1;
	my $bc_id=sprintf("%7d",$id);
	$bc_id=~tr/ /0/;
	$barcode=$barcode_type.$authority.$bc_id;
	my @digits=split(//,$barcode);
	my $odd_even;
	my $total=0;
	my $checkdigit;
	my $remainder;
	foreach my $digit (@digits)
	{
		if ($digit%2==0)
		{
			$total=$total+$digit;
		}
		else
		{
			$digit=$digit*2;
			if ($digit>=10)
			{
				$digit=$digit-9;
			}
			$total=$total+$digit;
		}
	}
	$remainder=$total%10;
	if ($remainder==0)
	{
		$checkdigit=0;
	}
	else
	{
		$checkdigit=10-$remainder;
	}
	$barcode=$barcode."-".$checkdigit;
	return $barcode;
}

# Load our localized strings - lame, need to convert to Locale::Maketext
sub load_i18n {
    foreach my $string_bundle (glob("$templates/password-reset/strings.*")) {
        open(I18NFH, '<', $string_bundle);
        (my $locale = $string_bundle) =~ s/^.*\.([a-z]{2}-[A-Z]{2})$/$1/;
        $logger->debug("Loaded locale [$locale] from file: [$string_bundle]");
        while(<I18NFH>) {
            my ($string_id, $string) = ($_ =~ m/^(.+?)=(.*?)$/);
            $i18n->{$locale}{$string_id} = $string;
        }
        close(I18NFH);
    }
}

1;

