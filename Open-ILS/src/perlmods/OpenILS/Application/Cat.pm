use strict; use warnings;
package OpenILS::Application::Cat;
use OpenILS::Application::AppUtils;
use OpenILS::Application;
use OpenILS::Application::Cat::Merge;
use OpenILS::Application::Cat::Authority;
use OpenILS::Application::Cat::BibCommon;
use base qw/OpenILS::Application/;
use Time::HiRes qw(time);
use OpenSRF::EX qw(:try);
use OpenSRF::Utils::JSON;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Event;
use OpenILS::Const qw/:const/;

use XML::LibXML;
use Unicode::Normalize;
use Data::Dumper;
use OpenILS::Utils::FlatXML;
use OpenILS::Utils::CStoreEditor q/:funcs/;
use OpenILS::Perm;
use OpenSRF::Utils::SettingsClient;
use OpenSRF::Utils::Logger qw($logger);
use OpenSRF::AppSession;

my $U = "OpenILS::Application::AppUtils";
my $conf;
my %marctemplates;

__PACKAGE__->register_method(
	method	=> "retrieve_marc_template",
	api_name	=> "open-ils.cat.biblio.marc_template.retrieve",
	notes		=> <<"	NOTES");
	Returns a MARC 'record tree' based on a set of pre-defined templates.
	Templates include : book
	NOTES

sub retrieve_marc_template {
	my( $self, $client, $type ) = @_;
	return $marctemplates{$type} if defined($marctemplates{$type});
	$marctemplates{$type} = _load_marc_template($type);
	return $marctemplates{$type};
}

__PACKAGE__->register_method(
	method => 'fetch_marc_template_types',
	api_name => 'open-ils.cat.marc_template.types.retrieve'
);

my $marc_template_files;

sub fetch_marc_template_types {
	my( $self, $conn ) = @_;
	__load_marc_templates();
	return [ keys %$marc_template_files ];
}

sub __load_marc_templates {
	return if $marc_template_files;
	if(!$conf) { $conf = OpenSRF::Utils::SettingsClient->new; }

	$marc_template_files = $conf->config_value(					
		"apps", "open-ils.cat","app_settings", "marctemplates" );

	$logger->info("Loaded marc templates: " . Dumper($marc_template_files));
}

sub _load_marc_template {
	my $type = shift;

	__load_marc_templates();

	my $template = $$marc_template_files{$type};
	open( F, $template ) or 
		throw OpenSRF::EX::ERROR ("Unable to open MARC template file: $template : $@");

	my @xml = <F>;
	close(F);
	my $xml = join('', @xml);

	return XML::LibXML->new->parse_string($xml)->documentElement->toString;
}



__PACKAGE__->register_method(
	method => 'fetch_bib_sources',
	api_name => 'open-ils.cat.bib_sources.retrieve.all');

sub fetch_bib_sources {
	return OpenILS::Application::Cat::BibCommon->fetch_bib_sources();
}

__PACKAGE__->register_method(
	method	=> "create_record_xml",
	api_name	=> "open-ils.cat.biblio.record.xml.create.override",
	signature	=> q/@see open-ils.cat.biblio.record.xml.create/);

__PACKAGE__->register_method(
	method		=> "create_record_xml",
	api_name		=> "open-ils.cat.biblio.record.xml.create",
	signature	=> q/
		Inserts a new biblio with the given XML
	/
);

sub create_record_xml {
	my( $self, $client, $login, $xml, $source ) = @_;

	my $override = 1 if $self->api_name =~ /override/;

	my( $user_obj, $evt ) = $U->checksesperm($login, 'CREATE_MARC');
	return $evt if $evt;

	$logger->activity("user ".$user_obj->id." creating new MARC record");

	my $meth = $self->method_lookup("open-ils.cat.biblio.record.xml.import");

	$meth = $self->method_lookup(
		"open-ils.cat.biblio.record.xml.import.override") if $override;

	my ($s) = $meth->run($login, $xml, $source);
	return $s;
}



__PACKAGE__->register_method(
	method	=> "biblio_record_replace_marc",
	api_name	=> "open-ils.cat.biblio.record.xml.update",
	argc		=> 3, 
	signature	=> q/
		Updates the XML for a given biblio record.
		This does not change any other aspect of the record entry
		exception the XML, the editor, and the edit date.
		@return The update record object
	/
);

__PACKAGE__->register_method(
	method		=> 'biblio_record_replace_marc',
	api_name		=> 'open-ils.cat.biblio.record.marc.replace',
	signature	=> q/
		@param auth The authtoken
		@param recid The record whose MARC we're replacing
		@param newxml The new xml to use
	/
);

__PACKAGE__->register_method(
	method		=> 'biblio_record_replace_marc',
	api_name		=> 'open-ils.cat.biblio.record.marc.replace.override',
	signature	=> q/@see open-ils.cat.biblio.record.marc.replace/
);

sub biblio_record_replace_marc  {
	my( $self, $conn, $auth, $recid, $newxml, $source ) = @_;
	my $e = new_editor(authtoken=>$auth, xact=>1);
	return $e->die_event unless $e->checkauth;
	return $e->die_event unless $e->allowed('CREATE_MARC', $e->requestor->ws_ou);

    my $res = OpenILS::Application::Cat::BibCommon->biblio_record_replace_marc(
        $e, $recid, $newxml, $source, 
        $self->api_name =~ /replace/o,
        $self->api_name =~ /override/o);

    $e->commit unless $U->event_code($res);
    return $res;
}

__PACKAGE__->register_method(
	method	=> "update_biblio_record_entry",
	api_name	=> "open-ils.cat.biblio.record_entry.update",
    signature => q/
        Updates a biblio.record_entry
        @param auth The authtoken
        @param record The record with updated values
        @return 1 on success, Event on error.
    /
);

sub update_biblio_record_entry {
    my($self, $conn, $auth, $record) = @_;
    my $e = new_editor(authtoken=>$auth, xact=>1);
    return $e->die_event unless $e->checkauth;
    return $e->die_event unless $e->allowed('UPDATE_RECORD');
    $e->update_biblio_record_entry($record) or return $e->die_event;
    $e->commit;
    return 1;
}

__PACKAGE__->register_method(
	method	=> "undelete_biblio_record_entry",
	api_name	=> "open-ils.cat.biblio.record_entry.undelete",
    signature => q/
        Un-deletes a record and sets active=true
        @param auth The authtoken
        @param record The record_id to ressurect
        @return 1 on success, Event on error.
    /
);
sub undelete_biblio_record_entry {
    my($self, $conn, $auth, $record_id) = @_;
    my $e = new_editor(authtoken=>$auth, xact=>1);
    return $e->die_event unless $e->checkauth;
    return $e->die_event unless $e->allowed('UPDATE_RECORD');

    my $record = $e->retrieve_biblio_record_entry($record_id)
        or return $e->die_event;
    $record->deleted('f');
    $record->active('t');

    # no 2 non-deleted records can have the same tcn_value
    my $existing = $e->search_biblio_record_entry(
        {   deleted => 'f', 
            tcn_value => $record->tcn_value, 
            id => {'!=' => $record_id}
        }, {idlist => 1});
    return OpenILS::Event->new('TCN_EXISTS') if @$existing;

    $e->update_biblio_record_entry($record) or return $e->die_event;
    $e->commit;
    return 1;
}


__PACKAGE__->register_method(
	method	=> "biblio_record_xml_import",
	api_name	=> "open-ils.cat.biblio.record.xml.import.override",
	signature	=> q/@see open-ils.cat.biblio.record.xml.import/);

__PACKAGE__->register_method(
	method	=> "biblio_record_xml_import",
	api_name	=> "open-ils.cat.biblio.record.xml.import",
	notes		=> <<"	NOTES");
	Takes a marcxml record and imports the record into the database.  In this
	case, the marcxml record is assumed to be a complete record (i.e. valid
	MARC).  The title control number is taken from (whichever comes first)
	tags 001, 039[ab], 020a, 022a, 010, 035a and whichever does not already exist
	in the database.
	user_session must have IMPORT_MARC permissions
	NOTES


sub biblio_record_xml_import {
	my( $self, $client, $authtoken, $xml, $source, $auto_tcn) = @_;
    my $e = new_editor(xact=>1, authtoken=>$authtoken);
    return $e->die_event unless $e->checkauth;
    return $e->die_event unless $e->allowed('IMPORT_MARC', $e->requestor->ws_ou);

    my $res = OpenILS::Application::Cat::BibCommon->biblio_record_xml_import(
        $e, $xml, $source, $auto_tcn, $self->api_name =~ /override/);

    $e->commit unless $U->event_code($res);
    return $res;
}

__PACKAGE__->register_method(
	method	=> "biblio_record_record_metadata",
	api_name	=> "open-ils.cat.biblio.record.metadata.retrieve",
    authoritative => 1,
	argc		=> 1, #(session_id, biblio_tree ) 
	notes		=> "Walks the tree and commits any changed nodes " .
					"adds any new nodes, and deletes any deleted nodes",
);

sub biblio_record_record_metadata {
	my( $self, $client, $authtoken, $ids ) = @_;

	return [] unless $ids and @$ids;

	my $editor = new_editor(authtoken => $authtoken);
	return $editor->event unless $editor->checkauth;
	return $editor->event unless $editor->allowed('VIEW_USER');

	my @results;

	for(@$ids) {
		return $editor->event unless 
			my $rec = $editor->retrieve_biblio_record_entry($_);
		$rec->creator($editor->retrieve_actor_user($rec->creator));
		$rec->editor($editor->retrieve_actor_user($rec->editor));
		$rec->clear_marc; # slim the record down
		push( @results, $rec );
	}

	return \@results;
}



__PACKAGE__->register_method(
	method	=> "biblio_record_marc_cn",
	api_name	=> "open-ils.cat.biblio.record.marc_cn.retrieve",
	argc		=> 1, #(bib id ) 
);

sub biblio_record_marc_cn {
	my( $self, $client, $id ) = @_;

	my $session = OpenSRF::AppSession->create("open-ils.cstore");
	my $marc = $session
		->request("open-ils.cstore.direct.biblio.record_entry.retrieve", $id )
		->gather(1)
		->marc;

	my $doc = XML::LibXML->new->parse_string($marc);
	$doc->documentElement->setNamespace( "http://www.loc.gov/MARC21/slim", "marc", 1 );
	
	my @res;
	for my $tag ( qw/050 055 060 070 080 082 086 088 090 092 096 098 099/ ) {
		my @node = $doc->findnodes("//marc:datafield[\@tag='$tag']");
		for my $x (@node) {
			my $cn = $x->findvalue("marc:subfield[\@code='a' or \@code='b']");
			push @res, {$tag => $cn} if ($cn);
		}
	}

	return \@res
}


__PACKAGE__->register_method(
	method	=> "orgs_for_title",
    authoritative => 1,
	api_name	=> "open-ils.cat.actor.org_unit.retrieve_by_title"
);

sub orgs_for_title {
	my( $self, $client, $record_id ) = @_;

	my $vols = $U->simple_scalar_request(
		"open-ils.cstore",
		"open-ils.cstore.direct.asset.call_number.search.atomic",
		{ record => $record_id, deleted => 'f' });

	my $orgs = { map {$_->owning_lib => 1 } @$vols };
	return [ keys %$orgs ];
}


__PACKAGE__->register_method(
	method	=> "retrieve_copies",
    authoritative => 1,
	api_name	=> "open-ils.cat.asset.copy_tree.retrieve");

__PACKAGE__->register_method(
	method	=> "retrieve_copies",
	api_name	=> "open-ils.cat.asset.copy_tree.global.retrieve");

# user_session may be null/undef
sub retrieve_copies {

	my( $self, $client, $user_session, $docid, @org_ids ) = @_;

	if(ref($org_ids[0])) { @org_ids = @{$org_ids[0]}; }

	$docid = "$docid";

	# grabbing copy trees should be available for everyone..
	if(!@org_ids and $user_session) {
		my $user_obj = 
			OpenILS::Application::AppUtils->check_user_session( $user_session ); #throws EX on error
			@org_ids = ($user_obj->home_ou);
	}

	if( $self->api_name =~ /global/ ) {
		return _build_volume_list( { record => $docid, deleted => 'f' } );

	} else {

		my @all_vols;
		for my $orgid (@org_ids) {
			my $vols = _build_volume_list( 
					{ record => $docid, owning_lib => $orgid, deleted => 'f' } );
			push( @all_vols, @$vols );
		}
		
		return \@all_vols;
	}

	return undef;
}


sub _build_volume_list {
	my $search_hash = shift;

	$search_hash->{deleted} = 'f';
	my $e = new_editor();

	my $vols = $e->search_asset_call_number($search_hash);

	my @volumes;

	for my $volume (@$vols) {

		my $copies = $e->search_asset_copy(
			{ call_number => $volume->id , deleted => 'f' });

		$copies = [ sort { $a->barcode cmp $b->barcode } @$copies  ];

		for my $c (@$copies) {
			if( $c->status == OILS_COPY_STATUS_CHECKED_OUT ) {
				$c->circulations(
					$e->search_action_circulation(
						[
							{ target_copy => $c->id },
							{
								order_by => { circ => 'xact_start desc' },
								limit => 1
							}
						]
					)
				)
			}
		}

		$volume->copies($copies);
		push( @volumes, $volume );
	}

	#$session->disconnect();
	return \@volumes;

}


__PACKAGE__->register_method(
	method	=> "fleshed_copy_update",
	api_name	=> "open-ils.cat.asset.copy.fleshed.batch.update",);

__PACKAGE__->register_method(
	method	=> "fleshed_copy_update",
	api_name	=> "open-ils.cat.asset.copy.fleshed.batch.update.override",);


sub fleshed_copy_update {
	my( $self, $conn, $auth, $copies, $delete_stats ) = @_;
	return 1 unless ref $copies;
	my( $reqr, $evt ) = $U->checkses($auth);
	return $evt if $evt;
	my $editor = new_editor(requestor => $reqr, xact => 1);
	my $override = $self->api_name =~ /override/;
	$evt = update_fleshed_copies($editor, $override, undef, $copies, $delete_stats);
	if( $evt ) { 
		$logger->info("fleshed copy update failed with event: ".OpenSRF::Utils::JSON->perl2JSON($evt));
		$editor->rollback; 
		return $evt; 
	}
	$editor->commit;
	$logger->info("fleshed copy update successfully updated ".scalar(@$copies)." copies");
	return 1;
}


__PACKAGE__->register_method(
	method => 'merge',
	api_name	=> 'open-ils.cat.biblio.records.merge',
	signature	=> q/
		Merges a group of records
		@param auth The login session key
		@param master The id of the record all other records should be merged into
		@param records Array of records to be merged into the master record
		@return 1 on success, Event on error.
	/
);

sub merge {
	my( $self, $conn, $auth, $master, $records ) = @_;
	my( $reqr, $evt ) = $U->checkses($auth);
	return $evt if $evt;
	my $editor = new_editor( requestor => $reqr, xact => 1 );
	my $v = OpenILS::Application::Cat::Merge::merge_records($editor, $master, $records);
	return $v if $v;
	$editor->commit;
    # tell the client the merge is complete, then merge the holds
    $conn->respond_complete(1);
    merge_holds($master, $records);
	return undef;
}

sub merge_holds {
    my($master, $records) = @_;
    return unless $master and @$records;
    return if @$records == 1 and $master == $$records[0];

    my $e = new_editor(xact=>1);
    my $holds = $e->search_action_hold_request(
        {   cancel_time => undef, 
            fulfillment_time => undef,
            hold_type => 'T',
            target => $records
        },
        {idlist=>1}
    );

    for my $hold_id (@$holds) {

        my $hold = $e->retrieve_action_hold_request($hold_id);

        $logger->info("Changing hold ".$hold->id.
            " target from ".$hold->target." to $master in record merge");

        $hold->target($master);
        unless($e->update_action_hold_request($hold)) {
            my $evt = $e->event;
            $logger->error("Error updating hold ". $evt->textcode .":". $evt->desc .":". $evt->stacktrace); 
        }
    }

    $e->commit;
    return undef;
}




# ---------------------------------------------------------------------------
# returns true if the given title (id) has no un-deleted volumes or 
# copies attached.  If a context volume is defined, a record
# is considered empty only if the context volume is the only
# remaining volume on the record.  
# ---------------------------------------------------------------------------
sub title_is_empty {
	my( $editor, $rid, $vol_id ) = @_;

	return 0 if $rid == OILS_PRECAT_RECORD;

	my $cnlist = $editor->search_asset_call_number(
		{ record => $rid, deleted => 'f' }, { idlist => 1 } );

	return 1 unless @$cnlist; # no attached volumes
    return 0 if @$cnlist > 1; # multiple attached volumes
    return 0 unless $$cnlist[0] == $vol_id; # attached volume is not the context vol.

    # see if the sole remaining context volume has any attached copies
	for my $cn (@$cnlist) {
		my $copylist = $editor->search_asset_copy(
			[
				{ call_number => $cn, deleted => 'f' }, 
				{ limit => 1 },
			], { idlist => 1 });
		return 0 if @$copylist; # false if we find any copies
	}

	return 1;
}


__PACKAGE__->register_method(
	method	=> "fleshed_volume_update",
	api_name	=> "open-ils.cat.asset.volume.fleshed.batch.update",);

__PACKAGE__->register_method(
	method	=> "fleshed_volume_update",
	api_name	=> "open-ils.cat.asset.volume.fleshed.batch.update.override",);

sub fleshed_volume_update {
	my( $self, $conn, $auth, $volumes, $delete_stats ) = @_;
	my( $reqr, $evt ) = $U->checkses($auth);
	return $evt if $evt;

	my $override = ($self->api_name =~ /override/);
	my $editor = new_editor( requestor => $reqr, xact => 1 );

	for my $vol (@$volumes) {
		$logger->info("vol-update: investigating volume ".$vol->id);

		$vol->editor($reqr->id);
		$vol->edit_date('now');

		my $copies = $vol->copies;
		$vol->clear_copies;

		$vol->editor($editor->requestor->id);
		$vol->edit_date('now');

		if( $vol->isdeleted ) {

			$logger->info("vol-update: deleting volume");
			my $cs = $editor->search_asset_copy(
				{ call_number => $vol->id, deleted => 'f' } );
			return OpenILS::Event->new(
				'VOLUME_NOT_EMPTY', payload => $vol->id ) if @$cs;

			$vol->deleted('t');
			return $editor->event unless
				$editor->update_asset_call_number($vol);

			
		} elsif( $vol->isnew ) {
			$logger->info("vol-update: creating volume");
			$evt = create_volume( $override, $editor, $vol );
			return $evt if $evt;

		} elsif( $vol->ischanged ) {
			$logger->info("vol-update: update volume");
			$evt = update_volume($vol, $editor);
			return $evt if $evt;
		}

		# now update any attached copies
		if( $copies and @$copies and !$vol->isdeleted ) {
			$_->call_number($vol->id) for @$copies;
			$evt = update_fleshed_copies( $editor, $override, $vol, $copies, $delete_stats );
			return $evt if $evt;
		}
	}

	$editor->finish;
	return scalar(@$volumes);
}


sub update_volume {
	my $vol = shift;
	my $editor = shift;
	my $evt;

	return $evt if ( $evt = org_cannot_have_vols($editor, $vol->owning_lib) );

	my $vols = $editor->search_asset_call_number( { 
			owning_lib	=> $vol->owning_lib,
			record		=> $vol->record,
			label			=> $vol->label,
			deleted		=> 'f'
		}
	);

	# There exists a different volume in the DB with the same properties
	return OpenILS::Event->new('VOLUME_LABEL_EXISTS', payload => $vol->id)
		if grep { $_->id ne $vol->id } @$vols;

	return $editor->event unless $editor->update_asset_call_number($vol);
	return undef;
}



sub copy_perm_org {
	my( $vol, $copy ) = @_;
	my $org = $vol->owning_lib;
	if( $vol->id == OILS_PRECAT_CALL_NUMBER ) {
		$org = ref($copy->circ_lib) ? $copy->circ_lib->id : $copy->circ_lib;
	}
	$logger->debug("using copy perm org $org");
	return $org;
}


# this does the actual work
sub update_fleshed_copies {
	my( $editor, $override, $vol, $copies, $delete_stats ) = @_;

	my $evt;
	my $fetchvol = ($vol) ? 0 : 1;

	my %cache;
	$cache{$vol->id} = $vol if $vol;

	for my $copy (@$copies) {

		my $copyid = $copy->id;
		$logger->info("vol-update: inspecting copy $copyid");

		if( !($vol = $cache{$copy->call_number}) ) {
			$vol = $cache{$copy->call_number} = 
				$editor->retrieve_asset_call_number($copy->call_number);
			return $editor->event unless $vol;
		}

		return $editor->event unless 
			$editor->allowed('UPDATE_COPY', copy_perm_org($vol, $copy));

		$copy->editor($editor->requestor->id);
		$copy->edit_date('now');

		$copy->status( $copy->status->id ) if ref($copy->status);
		$copy->location( $copy->location->id ) if ref($copy->location);
		$copy->circ_lib( $copy->circ_lib->id ) if ref($copy->circ_lib);
		
		my $sc_entries = $copy->stat_cat_entries;
		$copy->clear_stat_cat_entries;

		if( $copy->isdeleted ) {
			$evt = delete_copy($editor, $override, $vol, $copy);
			return $evt if $evt;

		} elsif( $copy->isnew ) {
			$evt = create_copy( $editor, $vol, $copy );
			return $evt if $evt;

		} elsif( $copy->ischanged ) {

			$evt = update_copy( $editor, $override, $vol, $copy );
			return $evt if $evt;
		}

		$copy->stat_cat_entries( $sc_entries );
		$evt = update_copy_stat_entries($editor, $copy, $delete_stats);
		return $evt if $evt;
	}

	$logger->debug("vol-update: done updating copy batch");

	return undef;
}

sub fix_copy_price {
	my $copy = shift;

    if(defined $copy->price) {
	    my $p = $copy->price || 0;
	    $p =~ s/\$//og;
	    $copy->price($p);
    }

	my $d = $copy->deposit_amount || 0;
	$d =~ s/\$//og;
	$copy->deposit_amount($d);
}


sub update_copy {
	my( $editor, $override, $vol, $copy ) = @_;

	my $evt;
	my $org = (ref $copy->circ_lib) ? $copy->circ_lib->id : $copy->circ_lib;
	return $evt if ( $evt = org_cannot_have_vols($editor, $org) );

	$logger->info("vol-update: updating copy ".$copy->id);
	my $orig_copy = $editor->retrieve_asset_copy($copy->id);
	my $orig_vol  = $editor->retrieve_asset_call_number($copy->call_number);

	$copy->editor($editor->requestor->id);
	$copy->edit_date('now');

	$copy->age_protect( $copy->age_protect->id )
		if ref $copy->age_protect;

	fix_copy_price($copy);

	return $editor->event unless $editor->update_asset_copy($copy);
	return remove_empty_objects($editor, $override, $orig_vol);
}


sub remove_empty_objects {
	my( $editor, $override, $vol ) = @_; 

    my $koe = $U->ou_ancestor_setting_value(
        $editor->requestor->ws_ou, 'cat.bib.keep_on_empty', $editor);
    my $aoe =  $U->ou_ancestor_setting_value(
        $editor->requestor->ws_ou, 'cat.bib.alert_on_empty', $editor);

	if( title_is_empty($editor, $vol->record, $vol->id) ) {

        # delete this volume if it's not already marked as deleted
        unless( $U->is_true($vol->deleted) || $vol->isdeleted ) {
            $vol->deleted('t');
            $vol->editor($editor->requestor->id);
            $vol->edit_date('now');
            $editor->update_asset_call_number($vol) or return $editor->event;
        }

        unless($koe) {
            # delete the bib record if the keep-on-empty setting is not set
            my $evt = delete_rec($editor, $vol->record);
            return $evt if $evt;
        }

        # return the empty alert if the alert-on-empty setting is set
        return OpenILS::Event->new('TITLE_LAST_COPY', payload => $vol->record ) if $aoe;
	}

	return undef;
}


__PACKAGE__->register_method (
	method => 'delete_bib_record',
	api_name => 'open-ils.cat.biblio.record_entry.delete');

sub delete_bib_record {
    my($self, $conn, $auth, $rec_id) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;
    return $e->die_event unless $e->allowed('DELETE_RECORD', $e->requestor->ws_ou);
    my $vols = $e->search_asset_call_number({record=>$rec_id, deleted=>'f'});
    return OpenILS::Event->new('RECORD_NOT_EMPTY', payload=>$rec_id) if @$vols;
    my $evt = delete_rec($e, $rec_id);
    if($evt) { $e->rollback; return $evt; }   
    $e->commit;
    return 1;
}


# marks a record as deleted
sub delete_rec {
   my( $editor, $rec_id ) = @_;

   my $rec = $editor->retrieve_biblio_record_entry($rec_id)
      or return $editor->event;

   return undef if $U->is_true($rec->deleted);
   
   $rec->deleted('t');
   $rec->active('f');
   $rec->editor( $editor->requestor->id );
   $rec->edit_date('now');
   $editor->update_biblio_record_entry($rec) or return $editor->event;

   return undef;
}


sub delete_copy {
	my( $editor, $override, $vol, $copy ) = @_;

   return $editor->event unless 
      $editor->allowed('DELETE_COPY',copy_perm_org($vol, $copy));

	my $stat = $U->copy_status($copy->status)->id;

	unless($override) {
		return OpenILS::Event->new('COPY_DELETE_WARNING', payload => $copy->id )
			if $stat == OILS_COPY_STATUS_CHECKED_OUT or
				$stat == OILS_COPY_STATUS_IN_TRANSIT or
				$stat == OILS_COPY_STATUS_ON_HOLDS_SHELF or
				$stat == OILS_COPY_STATUS_ILL;
	}

	$logger->info("vol-update: deleting copy ".$copy->id);
	$copy->deleted('t');

	$copy->editor($editor->requestor->id);
	$copy->edit_date('now');
	$editor->update_asset_copy($copy) or return $editor->event;

	# Delete any open transits for this copy
	my $transits = $editor->search_action_transit_copy(
		{ target_copy=>$copy->id, dest_recv_time => undef } );

	for my $t (@$transits) {
		$editor->delete_action_transit_copy($t)
			or return $editor->event;
	}

	return remove_empty_objects($editor, $override, $vol);
}


sub create_copy {
	my( $editor, $vol, $copy ) = @_;

	my $existing = $editor->search_asset_copy(
		{ barcode => $copy->barcode, deleted => 'f' } );
	
	return OpenILS::Event->new('ITEM_BARCODE_EXISTS') if @$existing;

   # see if the volume this copy references is marked as deleted
   my $evol = $editor->retrieve_asset_call_number($copy->call_number)
      or return $editor->event;
   return OpenILS::Event->new('VOLUME_DELETED', vol => $evol->id) 
      if $U->is_true($evol->deleted);

	my $evt;
	my $org = (ref $copy->circ_lib) ? $copy->circ_lib->id : $copy->circ_lib;
	return $evt if ( $evt = org_cannot_have_vols($editor, $org) );

	$copy->clear_id;
	$copy->creator($editor->requestor->id);
	$copy->create_date('now');
	fix_copy_price($copy);

	$editor->create_asset_copy($copy) or return $editor->event;
	return undef;
}

# if 'delete_stats' is true, the copy->stat_cat_entries data is 
# treated as the authoritative list for the copy. existing entries
# that are not in said list will be deleted from the DB
sub update_copy_stat_entries {
	my( $editor, $copy, $delete_stats ) = @_;

	return undef if $copy->isdeleted;
	return undef unless $copy->ischanged or $copy->isnew;

	my $evt;
	my $entries = $copy->stat_cat_entries;

	if( $delete_stats ) {
		$entries = ($entries and @$entries) ? $entries : [];
	} else {
		return undef unless ($entries and @$entries);
	}

	my $maps = $editor->search_asset_stat_cat_entry_copy_map({owning_copy=>$copy->id});

	if(!$copy->isnew) {
		# if there is no stat cat entry on the copy who's id matches the
		# current map's id, remove the map from the database
		for my $map (@$maps) {
			if(! grep { $_->id == $map->stat_cat_entry } @$entries ) {

				$logger->info("copy update found stale ".
					"stat cat entry map ".$map->id. " on copy ".$copy->id);

				$editor->delete_asset_stat_cat_entry_copy_map($map)
					or return $editor->event;
			}
		}
	}

	# go through the stat cat update/create process
	for my $entry (@$entries) { 
		next unless $entry;

		# if this link already exists in the DB, don't attempt to re-create it
		next if( grep{$_->stat_cat_entry == $entry->id} @$maps );
	
		my $new_map = Fieldmapper::asset::stat_cat_entry_copy_map->new();

		my $sc = ref($entry->stat_cat) ? $entry->stat_cat->id : $entry->stat_cat;
		
		$new_map->stat_cat( $sc );
		$new_map->stat_cat_entry( $entry->id );
		$new_map->owning_copy( $copy->id );

		$editor->create_asset_stat_cat_entry_copy_map($new_map)
			or return $editor->event;

		$logger->info("copy update created new stat cat entry map ".$editor->data);
	}

	return undef;
}


sub create_volume {
	my( $override, $editor, $vol ) = @_;
	my $evt;

	return $evt if ( $evt = org_cannot_have_vols($editor, $vol->owning_lib) );

   # see if the record this volume references is marked as deleted
   my $rec = $editor->retrieve_biblio_record_entry($vol->record)
      or return $editor->event;
   return OpenILS::Event->new('BIB_RECORD_DELETED', rec => $rec->id) 
      if $U->is_true($rec->deleted);

	# first lets see if there are any collisions
	my $vols = $editor->search_asset_call_number( { 
			owning_lib	=> $vol->owning_lib,
			record		=> $vol->record,
			label			=> $vol->label,
			deleted		=> 'f'
		}
	);

	my $label = undef;
	if(@$vols) {
      # we've found an exising volume
		if($override) { 
			$label = $vol->label;
		} else {
			return OpenILS::Event->new(
				'VOLUME_LABEL_EXISTS', payload => $vol->id);
		}
	}

	# create a temp label so we can create the new volume, 
   # then de-dup it with the existing volume
	$vol->label( "__SYSTEM_TMP_$$".time) if $label;

	$vol->creator($editor->requestor->id);
	$vol->create_date('now');
	$vol->editor($editor->requestor->id);
	$vol->edit_date('now');
	$vol->clear_id;

	$editor->create_asset_call_number($vol) or return $editor->event;

	if($label) {
		# now restore the label and merge into the existing record
		$vol->label($label);
		(undef, $evt) = 
			OpenILS::Application::Cat::Merge::merge_volumes($editor, [$vol], $$vols[0]);
		return $evt if $evt;
	}

	return undef;
}


__PACKAGE__->register_method (
	method => 'batch_volume_transfer',
	api_name => 'open-ils.cat.asset.volume.batch.transfer',
);

__PACKAGE__->register_method (
	method => 'batch_volume_transfer',
	api_name => 'open-ils.cat.asset.volume.batch.transfer.override',
);


sub batch_volume_transfer {
	my( $self, $conn, $auth, $args ) = @_;

	my $evt;
	my $rec		= $$args{docid};
	my $o_lib	= $$args{lib};
	my $vol_ids = $$args{volumes};

	my $override = 1 if $self->api_name =~ /override/;

	$logger->info("merge: transferring volumes to lib=$o_lib and record=$rec");

	my $e = new_editor(authtoken => $auth, xact =>1);
	return $e->event unless $e->checkauth;
	return $e->event unless $e->allowed('UPDATE_VOLUME', $o_lib);

	my $dorg = $e->retrieve_actor_org_unit($o_lib)
		or return $e->event;

	my $ou_type = $e->retrieve_actor_org_unit_type($dorg->ou_type)
		or return $e->event;

	return $evt if ( $evt = org_cannot_have_vols($e, $o_lib) );

	my $vols = $e->batch_retrieve_asset_call_number($vol_ids);
	my @seen;

   my @rec_ids;

	for my $vol (@$vols) {

		# if we've already looked at this volume, go to the next
		next if !$vol or grep { $vol->id == $_ } @seen;

		# grab all of the volumes in the list that have 
		# the same label so they can be merged
		my @all = grep { $_->label eq $vol->label } @$vols;

		# take note of the fact that we've looked at this set of volumes
		push( @seen, $_->id ) for @all;
      push( @rec_ids, $_->record ) for @all;

		# for each volume, see if there are any copies that have a 
		# remote circ_lib (circ_lib != vol->owning_lib and != $o_lib ).  
		# if so, warn them
		unless( $override ) {
			for my $v (@all) {

				$logger->debug("merge: searching for copies with remote circ_lib for volume ".$v->id);
				my $args = { 
					call_number	=> $v->id, 
					circ_lib		=> { "not in" => [ $o_lib, $v->owning_lib ] },
					deleted		=> 'f'
				};

				my $copies = $e->search_asset_copy($args, {idlist=>1});

				# if the copy's circ_lib matches the destination lib,
				# that's ok too
				return OpenILS::Event->new('COPY_REMOTE_CIRC_LIB') if @$copies;
			}
		}

		# see if there is a volume at the destination lib that 
		# already has the requested label
		my $existing_vol = $e->search_asset_call_number(
			{
				label			=> $vol->label, 
				record		=>$rec, 
				owning_lib	=>$o_lib,
				deleted		=> 'f'
			}
		)->[0];

		if( $existing_vol ) {

			if( grep { $_->id == $existing_vol->id } @all ) {
				# this volume is already accounted for in our list of volumes to merge
				$existing_vol = undef;

			} else {
				# this volume exists on the destination record/owning_lib and must
				# be used as the destination for merging
				$logger->debug("merge: volume already exists at destination record: ".
					$existing_vol->id.' : '.$existing_vol->label) if $existing_vol;
			}
		} 

		if( @all > 1 || $existing_vol ) {
			$logger->info("merge: found collisions in volume transfer");
			my @args = ($e, \@all);
			@args = ($e, \@all, $existing_vol) if $existing_vol;
			($vol, $evt) = OpenILS::Application::Cat::Merge::merge_volumes(@args);
			return $evt if $evt;
		} 
		
		if( !$existing_vol ) {

			$vol->owning_lib($o_lib);
			$vol->record($rec);
			$vol->editor($e->requestor->id);
			$vol->edit_date('now');
	
			$logger->info("merge: updating volume ".$vol->id);
			$e->update_asset_call_number($vol) or return $e->event;

		} else {
			$logger->info("merge: bypassing volume update because existing volume used as target");
		}

		# regardless of what volume was used as the destination, 
		# update any copies that have moved over to the new lib
		my $copies = $e->search_asset_copy({call_number=>$vol->id, deleted => 'f'});

		# update circ lib on the copies - make this a method flag?
		for my $copy (@$copies) {
			next if $copy->circ_lib == $o_lib;
			$logger->info("merge: transfer moving circ lib on copy ".$copy->id);
			$copy->circ_lib($o_lib);
			$copy->editor($e->requestor->id);
			$copy->edit_date('now');
			$e->update_asset_copy($copy) or return $e->event;
		}

		# Now see if any empty records need to be deleted after all of this

      for(@rec_ids) {
         $logger->debug("merge: seeing if we should delete record $_...");
         $evt = delete_rec($e, $_) if title_is_empty($e, $_);
			return $evt if $evt;
      }

		#for(@all) {
		#	$evt = remove_empty_objects($e, $override, $_);
		#}
	}

	$logger->info("merge: transfer succeeded");
	$e->commit;
	return 1;
}



sub org_cannot_have_vols {
	my $e = shift;
	my $org_id = shift;

	my $org = $e->retrieve_actor_org_unit($org_id)
		or return $e->event;

	my $ou_type = $e->retrieve_actor_org_unit_type($org->ou_type)
		or return $e->event;

	return OpenILS::Event->new('ORG_CANNOT_HAVE_VOLS')
		unless $U->is_true($ou_type->can_have_vols);

	return 0;
}




__PACKAGE__->register_method(
	api_name => 'open-ils.cat.call_number.find_or_create',
	method => 'find_or_create_volume',
);

sub find_or_create_volume {
	my( $self, $conn, $auth, $label, $record_id, $org_id ) = @_;
	my $e = new_editor(authtoken=>$auth, xact=>1);
	return $e->die_event unless $e->checkauth;

    my $vol;

    if($record_id == OILS_PRECAT_RECORD) {

        $vol = $e->retrieve_asset_call_number(OILS_PRECAT_CALL_NUMBER)
            or return $e->die_event;

    } else {
	
	    $vol = $e->search_asset_call_number(
		    {label => $label, record => $record_id, owning_lib => $org_id, deleted => 'f'}, 
		    {idlist=>1}
	    )->[0];
    }

	# If the volume exists, return the ID
	if( $vol ) { $e->rollback; return $vol; }

	# -----------------------------------------------------------------
	# Otherwise, create a new volume with the given attributes
	# -----------------------------------------------------------------

	return $e->die_event unless $e->allowed('UPDATE_VOLUME', $org_id);

	$vol = Fieldmapper::asset::call_number->new;
	$vol->owning_lib($org_id);
	$vol->label($label);
	$vol->record($record_id);

   my $evt = create_volume( 0, $e, $vol );
   return $evt if $evt;

	$e->commit;
	return $vol->id;
}



1;
