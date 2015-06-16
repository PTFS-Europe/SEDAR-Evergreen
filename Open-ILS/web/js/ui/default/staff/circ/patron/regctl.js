
angular.module('egCoreMod')
// toss tihs onto egCoreMod since the page app may vary

.factory('patronRegSvc', ['$q', 'egCore', function($q, egCore) {

    var service = {
        field_doc : {},             // config.idl_field_doc
        profiles : [],              // permission groups
        sms_carriers : [],
        user_settings : {},         // applied user settings
        user_setting_types : {},    // config.usr_setting_type
        modified_user_settings : {} // settings modifed this session
    };

    // launch a series of parallel data retrieval calls
    service.init = function(scope) {
        return $q.all([
            service.get_field_doc(),
            service.get_perm_groups(),
            service.get_ident_types(),
            service.get_user_settings(),
            service.get_org_settings(),
            service.get_stat_cats(),
            service.get_surveys(),
            service.get_net_access_levels()
        ]);
    };

    service.get_surveys = function() {
        var org_ids = egCore.org.ancestors(egCore.auth.user().ws_ou(), true);

        return egCore.pcrud.search('asv', 
            {owner : org_ids}, 
            {flesh : 1, flesh_fields : {asv : ['questions']}}, 
            {atomic : true}
        ).then(function(surveys) {
            service.surveys = surveys;
        });
    }

    service.get_stat_cats = function() {
        return egCore.net.request(
            'open-ils.circ',
            'open-ils.circ.stat_cat.actor.retrieve.all',
            egCore.auth.token(), egCore.auth.user().ws_ou()
        ).then(function(cats) {
            service.stat_cats = cats;
        });
    };

    service.get_org_settings = function() {
        return egCore.org.settings([
            'global.password_regex',
            'global.juvenile_age_threshold',
            'patron.password.use_phone',
            'ui.patron.default_inet_access_level',
            'ui.patron.default_ident_type',
            'ui.patron.default_country',
            'ui.patron.registration.require_address',
            'circ.holds.behind_desk_pickup_supported',
            'circ.patron_edit.clone.copy_address',
            'ui.patron.edit.au.prefix.require',
            'ui.patron.edit.au.prefix.show',
            'ui.patron.edit.au.prefix.suggest',
            'ui.patron.edit.ac.barcode.regex',
            'ui.patron.edit.au.second_given_name.show',
            'ui.patron.edit.au.second_given_name.suggest',
            'ui.patron.edit.au.suffix.show',
            'ui.patron.edit.au.suffix.suggest',
            'ui.patron.edit.au.alias.show',
            'ui.patron.edit.au.alias.suggest',
            'ui.patron.edit.au.dob.require',
            'ui.patron.edit.au.dob.show',
            'ui.patron.edit.au.dob.suggest',
            'ui.patron.edit.au.dob.calendar',
            'ui.patron.edit.au.juvenile.show',
            'ui.patron.edit.au.juvenile.suggest',
            'ui.patron.edit.au.ident_value.show',
            'ui.patron.edit.au.ident_value.suggest',
            'ui.patron.edit.au.ident_value2.show',
            'ui.patron.edit.au.ident_value2.suggest',
            'ui.patron.edit.au.email.require',
            'ui.patron.edit.au.email.show',
            'ui.patron.edit.au.email.suggest',
            'ui.patron.edit.au.email.regex',
            'ui.patron.edit.au.email.example',
            'ui.patron.edit.au.day_phone.require',
            'ui.patron.edit.au.day_phone.show',
            'ui.patron.edit.au.day_phone.suggest',
            'ui.patron.edit.au.day_phone.regex',
            'ui.patron.edit.au.day_phone.example',
            'ui.patron.edit.au.evening_phone.require',
            'ui.patron.edit.au.evening_phone.show',
            'ui.patron.edit.au.evening_phone.suggest',
            'ui.patron.edit.au.evening_phone.regex',
            'ui.patron.edit.au.evening_phone.example',
            'ui.patron.edit.au.other_phone.require',
            'ui.patron.edit.au.other_phone.show',
            'ui.patron.edit.au.other_phone.suggest',
            'ui.patron.edit.au.other_phone.regex',
            'ui.patron.edit.au.other_phone.example',
            'ui.patron.edit.phone.regex',
            'ui.patron.edit.phone.example',
            'ui.patron.edit.au.active.show',
            'ui.patron.edit.au.active.suggest',
            'ui.patron.edit.au.barred.show',
            'ui.patron.edit.au.barred.suggest',
            'ui.patron.edit.au.master_account.show',
            'ui.patron.edit.au.master_account.suggest',
            'ui.patron.edit.au.claims_returned_count.show',
            'ui.patron.edit.au.claims_returned_count.suggest',
            'ui.patron.edit.au.claims_never_checked_out_count.show',
            'ui.patron.edit.au.claims_never_checked_out_count.suggest',
            'ui.patron.edit.au.alert_message.show',
            'ui.patron.edit.au.alert_message.suggest',
            'ui.patron.edit.aua.post_code.regex',
            'ui.patron.edit.aua.post_code.example',
            'ui.patron.edit.aua.county.require',
            'format.date',
            'ui.patron.edit.default_suggested',
            'opac.barcode_regex',
            'opac.username_regex',
            'sms.enable',
            'ui.patron.edit.aua.state.require',
            'ui.patron.edit.aua.state.suggest',
            'ui.patron.edit.aua.state.show'
        ]).then(function(settings) {
            service.org_settings = settings;
            return service.process_org_settings(settings);
        });
    };

    // some org settings require the retrieval of additional data
    service.process_org_settings = function(settings) {

        if (!settings['sms.enable']) {
            return $q.when();
        }

        return egCore.pcrud.search('csc', 
            {active: 'true'}, 
            {'order_by':[
                {'class':'csc', 'field':'name'},
                {'class':'csc', 'field':'region'}
            ]},
            {atomic : true}
        ).then(function(carriers) {
            service.sms_carriers = carriers;
        });
    };

    service.get_ident_types = function() {
        return egCore.pcrud.retrieveAll('cit', {}, {atomic : true})
        .then(function(types) { service.ident_types = types });
    };

    service.get_net_access_levels = function() {
        return egCore.pcrud.retrieveAll('cnal', {}, {atomic : true})
        .then(function(levels) { service.net_access_levels = levels });
    }

    service.get_perm_groups = function() {
        if (egCore.env.pgt) {
            service.profiles = egCore.env.pgt.list;
            return $q.when();
        } else {
            return egCore.pcrud.search('pgt', {parent : null}, 
                {flesh : -1, flesh_fields : {pgt : ['children']}}
            ).then(
                function(tree) {
                    egCore.env.absorbTree(tree, 'pgt')
                    service.profiles = egCore.env.pgt.list;
                }
            );
        }
    }

    service.get_field_doc = function() {

        return egCore.pcrud.search('fdoc', {
            fm_class: ['au', 'ac', 'aua', 'actsc', 'asv', 'asvq', 'asva']})
        .then(null, null, function(doc) {
            if (!service.field_doc[doc.fm_class()]) {
                service.field_doc[doc.fm_class()] = {};
            }
            service.field_doc[doc.fm_class()][doc.field()] = doc;
        });
    };

    service.get_user_settings = function() {
        var org_ids = egCore.org.ancestors(egCore.auth.user().ws_ou(), true);

        return egCore.pcrud.search('cust', {
            '-or' : [
                {name : [ // common user settings
                    'circ.holds_behind_desk', 
                    'circ.collections.exempt', 
                    'opac.hold_notify', 
                    'opac.default_phone', 
                    'opac.default_pickup_location', 
                    'opac.default_sms_carrier', 
                    'opac.default_sms_notify']}, 
                {name : { // opt-in notification user settings
                    'in': {
                        select : {atevdef : ['opt_in_setting']}, 
                        from : 'atevdef',
                        // we only care about opt-in settings for 
                        // event_defs our users encounter
                        where : {'+atevdef' : {owner : org_ids}}
                    }
                }}
            ]
        }, {}, {atomic : true}).then(function(setting_types) {

            angular.forEach(setting_types, function(stype) {
                service.user_setting_types[stype.name()] = stype;
            });

            if(service.patron_id) {
                // retrieve applied values for the current user 
                // for the setting types we care about.

                var setting_names = 
                    setting_types.map(function(obj) { return obj.name() });

                return egCore.net.request(
                    'open-ils.actor', 
                    'open-ils.actor.patron.settings.retrieve.authoritative',
                    egCore.auth.token(),
                    service.patron_id,
                    setting_names
                ).then(function(settings) {
                    service.user_settings = settings;
                });
            }

            // apply default user setting values
            angular.forEach(setting_types, function(stype, index) {
                if (stype.reg_default() != undefined) {
                    service.modified_user_settings[setting.name()] = 
                        service.user_settings[setting.name()] = 
                        setting.reg_default();
                }
            });
        });
    }

    service.init_patron = function(current) {

        if (!current)
            return service.init_new_patron();

        service.patron = current;
        return service.init_existing_patron(current)
    }

    /*
     * Existing patron objects reqire some data munging before insertion
     * into the scope.
     *
     * 1. Turn everything into a hash
     * 2. ... Except certain fields (selectors) whose widgets require objects
     * 3. Bools must be Boolean, not t/f.
     */
    service.init_existing_patron = function(current) {

        var patron = egCore.idl.toHash(current);

        patron.home_ou = egCore.org.get(patron.home_ou.id);
        patron.expire_date = new Date(Date.parse(patron.expire_date));
        patron.dob = new Date(Date.parse(patron.dob));
        patron.profile = current.profile(); // pre-hash version
        patron.net_access_level = current.net_access_level();
        patron.ident_type = current.ident_type();

        angular.forEach(
            ['juvenile', 'barred', 'active', 'master_account'],
            function(field) { patron[field] = patron[field] == 't'; }
        );

        angular.forEach(patron.addresses, function(addr) {
            addr.valid = addr.valid == 't';
            addr.within_city_limits = addr.within_city_limits == 't';
        });

        return patron;
    }

    service.init_new_patron = function() {

        var addr = {
            valid : true,
            within_city_limits : true
            // default state, etc.
        };

        return {
            isnew : true,
            active : true,
            card : {},
            home_ou : egCore.org.get(egCore.auth.user().ws_ou()),
            // TODO default profile group?
            mailing_address : addr,
            addresses : [addr]
        };
    }

    return service;
}]);


function PatronRegCtrl($scope, $routeParams, 
    $q, egCore, patronSvc, patronRegSvc) {

    $scope.clone_id = $routeParams.clone_id;
    $scope.stage_username = $routeParams.stage_username;
    $scope.patron_id = 
        patronRegSvc.patron_id = $routeParams.edit_id || $routeParams.id;

    $q.all([

        $scope.initTab ? // initTab comes from patron app
            $scope.initTab('edit', $routeParams.id) : $q.when(),

        patronRegSvc.init()

    ]).then(function() {
        // called after initTab and patronRegSvc.init have completed

        var prs = patronRegSvc; // brevity
        // in standalone mode, we have no patronSvc
        $scope.patron = prs.init_patron(patronSvc ? patronSvc.current : null);
        $scope.field_doc = prs.field_doc;
        $scope.profiles = prs.profiles;
        $scope.ident_types = prs.ident_types;
        $scope.net_access_levels = prs.net_access_levels;
        $scope.user_settings = prs.user_settings;
        $scope.user_setting_types = prs.user_setting_types;
        $scope.modified_user_settings = prs.modified_user_settings;
        $scope.org_settings = prs.org_settings;
        $scope.sms_carriers = prs.sms_carriers;
        $scope.stat_cats = prs.stat_cats;
        $scope.surveys = prs.surveys;
    });

    // returns the tree depth of the selected profile group tree node.
    $scope.pgt_depth = function(grp) {
        var d = 0;
        while (grp = egCore.env.pgt.map[grp.parent()]) d++;
        return d;
    }

    // IDL fields used for labels in the UI.
    $scope.idl_fields = {
        au  : egCore.idl.classes.au.field_map,
        ac  : egCore.idl.classes.ac.field_map,
        aua : egCore.idl.classes.aua.field_map
    };

}


// TODO: $inject controller params 