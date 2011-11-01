#!/usr/bin/env perl 
use strict;
use warnings;
use 5.10.1;
use FindBin qw($Bin);
use File::Spec;
use XML::LibXML;
use File::Copy;
use Carp;

=header sedar_config.pl Customize Configuration For SEDAR

Add the sedar specific customizations into opensrf.xml
Similarly to eg_db_config

=cut

my $config_file = shift @ARGV;
my $script_dir  = $Bin;

my $eg_config = File::Spec->catfile( $script_dir, '../extras/eg_config' );

if ( !$config_file ) {
    my @temp = `$eg_config --sysconfdir`;
    chomp $temp[0];
    my $sysconfdir = $temp[0];
    $config_file = File::Spec->catfile( $sysconfdir, "opensrf.xml" );
}

update_config($config_file);

sub update_config {
    my $config_file = shift;

    my $parser = XML::LibXML->new(0);

    $parser->keep_blanks(0);
    my $opensrf_config = $parser->parse_file($config_file);
    my @nodes;

    # Use en_GB as default locale
    @nodes = $opensrf_config->findnodes('//default_locale/text()');
    for my $n (@nodes) {
        $n->setData('en-GB');
    }

    # set email addresses
    @nodes = $opensrf_config->findnodes('//sender_address/text()');
    for my $n (@nodes) {
        $n->setData('librarynotices@sedar.org.uk');
    }

    # Add NLS target replacing the oclc one
    my ($target) = $opensrf_config->findnodes('//z3950/services/oclc');
    my $t_parent = $target->parentNode;
    $t_parent->removeChild($target);

    my $nls = add_nls_target($opensrf_config);
    $t_parent->appendChild($nls);

    localize_amazon($opensrf_config);

    add_templates($opensrf_config);

    write_config_file( $config_file, $opensrf_config );
    return;
}

sub localize_amazon {
    my $doc  = shift;
    my ($ac) = $doc->findnodes('//added_content');
    my $node = $doc->createElement('added_content');
    my $e    = $doc->createElement('module');
    $e->appendText('OpenILS::WWW::AddedContent::Amazon');
    $node->addChild($e);
    $e = $doc->createElement('base_url');
    $e->appendText('http://images-eu.amazon.com/images/P/');
    $node->addChild($e);
    $e = $doc->createElement('timeout');
    $e->appendText('1');
    $node->addChild($e);
    $e = $doc->createElement('retry_timeout');
    $e->appendText('300');
    $node->addChild($e);
    $e = $doc->createElement('max_errors');
    $e->appendText('10');
    $node->addChild($e);
    $ac->replaceNode($node);

    return;
}

sub add_templates {
    my $doc    = shift;
    my ($node) = $doc->findnodes('//open-ils.cat/app_settings/marctemplates');
    my $t      = $doc->createElement('ST_Book');
    $t->appendText('/openils/var/templates/marc/k_stbook.xml');
    $node->appendChild($t);
    $t = $doc->createElement('ED_Book');
    $t->appendText('/openils/var/templates/marc/k_edbook.xml');
    $node->appendChild($t);
    $t = $doc->createElement('COMMINFO');
    $t->appendText('/openils/var/templates/marc/k_comminfo.xml');
    $node->appendChild($t);

    return;
}

sub add_nls_target {
    my $opensrf_config = shift;

    my $nls      = $opensrf_config->createElement('nls');
    my $nls_name = $opensrf_config->createElement('name');
    $nls_name->appendText('National Library of Scotland');
    my $nls_host = $opensrf_config->createElement('host');
    $nls_host->appendText('z3950.nls.uk');
    my $nls_port = $opensrf_config->createElement('port');
    $nls_port->appendText('7290');
    my $nls_db = $opensrf_config->createElement('db');
    $nls_db->appendText('voyager');
    my $nls_format = $opensrf_config->createElement('record_format');
    $nls_format->appendText('F');
    my $nls_tf = $opensrf_config->createElement('transmission_format');
    $nls_tf->appendText('usmarc');
    my $attr = $opensrf_config->createElement('attrs');
    add_attribute( $opensrf_config, $attr, 'tcn',       12,   1 );
    add_attribute( $opensrf_config, $attr, 'isbn',      7,    1 );
    add_attribute( $opensrf_config, $attr, 'lccn',      9,    1 );
    add_attribute( $opensrf_config, $attr, 'author',    1003, 1 );
    add_attribute( $opensrf_config, $attr, 'title',     4,    1 );
    add_attribute( $opensrf_config, $attr, 'issn',      8,    1 );
    add_attribute( $opensrf_config, $attr, 'publisher', 1018, 1 );
    add_attribute( $opensrf_config, $attr, 'pubdate',   31,   1 );
    add_attribute( $opensrf_config, $attr, 'item_type', 1001, 1 );

    $nls->addChild($nls_name);
    $nls->addChild($nls_host);
    $nls->addChild($nls_port);
    $nls->addChild($nls_db);
    $nls->addChild($nls_format);
    $nls->addChild($nls_tf);
    $nls->addChild($attr);
    return $nls;
}

sub add_attribute {
    my ( $doc, $p_node, $node_name, $code, $format ) = @_;

    my $node      = $doc->createElement($node_name);
    my $code_elem = $doc->createElement('code');
    $code_elem->appendText($code);
    my $format_elem = $doc->createElement('format');
    $format_elem->appendText($format);
    $node->addChild($code_elem);
    $node->addChild($format_elem);
    $p_node->appendChild($node);
    return;
}

sub write_config_file {
    my ( $config_file, $opensrf_config ) = @_;

    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
      localtime(time);
    my $timestamp = sprintf(
        '%d.%d.%d.%d.%d.%d',
        $year + 1900,
        $mon + 1, $mday, $hour, $min, $sec
    );
    if ( copy( $config_file, "$config_file.$timestamp" ) ) {
        say
          "Backed up original configuration file to '$config_file.$timestamp'";
    }
    else {
        carp "Unable to write to '$config_file.$timestamp'; aborted.";
    }

    $opensrf_config->toFile( $config_file, 2 )
      or croak "ERROR: Failed to update the configuration file '$config_file'";
    return;
}
