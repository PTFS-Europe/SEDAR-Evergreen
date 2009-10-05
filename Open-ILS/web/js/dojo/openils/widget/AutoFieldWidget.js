if(!dojo._hasResource['openils.widget.AutoFieldWidget']) {
    dojo.provide('openils.widget.AutoFieldWidget');
    dojo.require('openils.Util');
    dojo.require('openils.User');
    dojo.require('fieldmapper.IDL');
    dojo.require('openils.PermaCrud');
	dojo.requireLocalization("openils.widget", "AutoFieldWidget");

    dojo.declare('openils.widget.AutoFieldWidget', null, {

        async : false,

        /**
         * args:
         *  idlField -- Field description object from fieldmapper.IDL.fmclasses
         *  fmObject -- If available, the object being edited.  This will be used 
         *      to set the value of the widget.
         *  fmClass -- Class name (not required if idlField or fmObject is set)
         *  fmField -- Field name (not required if idlField)
         *  parentNode -- If defined, the widget will be appended to this DOM node
         *  dijitArgs -- Optional parameters object, passed directly to the dojo widget
         *  orgLimitPerms -- If this field defines a set of org units and an orgLimitPerms 
         *      is defined, the code will limit the org units in the set to those
         *      allowed by the permission
         */
        constructor : function(args) {
            for(var k in args)
                this[k] = args[k];

            // find the field description in the IDL if not provided
            if(this.fmObject) 
                this.fmClass = this.fmObject.classname;
            this.fmIDL = fieldmapper.IDL.fmclasses[this.fmClass];
            this.suppressLinkedFields = args.suppressLinkedFields || [];

            if(!this.idlField) {
                this.fmIDL = fieldmapper.IDL.fmclasses[this.fmClass];
                var fields = this.fmIDL.fields;
                for(var f in fields) 
                    if(fields[f].name == this.fmField)
                        this.idlField = fields[f];
            }

            if(!this.idlField) 
                throw new Error("AutoFieldWidget could not determine which field to render.  We need more information. fmClass=" + 
                    this.fmClass + ' fmField=' + this.fmField + ' fmObject=' + js2JSON(this.fmObject));

            this.auth = openils.User.authtoken;
            this.cache = openils.widget.AutoFieldWidget.cache;
            this.cache[this.auth] = this.cache[this.auth] || {};
            this.cache[this.auth].single = this.cache[this.auth].single || {};
            this.cache[this.auth].list = this.cache[this.auth].list || {};
        },

        /**
         * Turn the widget-stored value into a value oils understands
         */
        getFormattedValue : function() {
            var value = this.baseWidgetValue();
            switch(this.idlField.datatype) {
                case 'bool':
                    return (value) ? 't' : 'f'
                case 'timestamp':
                    if(!value) return null;
                    return dojo.date.stamp.toISOString(value);
                case 'int':
                case 'float':
                case 'money':
                    if(isNaN(value)) value = 0;
                default:
                    return (value === '') ? null : value;
            }
        },

        baseWidgetValue : function(value) {
            var attr = (this.readOnly) ? 'content' : 'value';
            if(arguments.length) this.widget.attr(attr, value);
            return this.widget.attr(attr);
        },
        
        /**
         * Turn the widget-stored value into something visually suitable
         */
        getDisplayString : function() {
            var value = this.widgetValue;
            switch(this.idlField.datatype) {
                case 'bool':
                    return (openils.Util.isTrue(value)) ? 
                        openils.widget.AutoFieldWidget.localeStrings.TRUE : 
                        openils.widget.AutoFieldWidget.localeStrings.FALSE;
                case 'timestamp':
                    dojo.require('dojo.date.locale');
                    dojo.require('dojo.date.stamp');
                    var date = dojo.date.stamp.fromISOString(value);
                    return dojo.date.locale.format(date, {formatLength:'short'});
                case 'org_unit':
                    if(value === null || value === undefined) return '';
                    return fieldmapper.aou.findOrgUnit(value).shortname();
                case 'int':
                case 'float':
                    if(isNaN(value)) value = 0;
                default:
                    if(value === undefined || value === null)
                        value = '';
                    return value+'';
            }
        },

        build : function(onload) {

            if(this.widget) {
                // core widget provided for us, attach and move on
                if(this.parentNode) // may already be in the "right" place
                    this.parentNode.appendChild(this.widget.domNode);
                return;
            }
            
            if(!this.parentNode) // give it somewhere to live so that dojo won't complain
                this.parentNode = dojo.create('div');

            this.onload = onload;
            if(this.widgetValue == null)
                this.widgetValue = (this.fmObject) ? this.fmObject[this.idlField.name]() : null;

            if(this.readOnly) {
                dojo.require('dijit.layout.ContentPane');
                this.widget = new dijit.layout.ContentPane(this.dijitArgs, this.parentNode);
                if(this.widgetValue !== null)
                    this._tryLinkedDisplayField();

            } else if(this.widgetClass) {
                dojo.require(this.widgetClass);
                eval('this.widget = new ' + this.widgetClass + '(this.dijitArgs, this.parentNode);');

            } else {

                switch(this.idlField.datatype) {
                    
                    case 'id':
                        dojo.require('dijit.form.TextBox');
                        this.widget = new dijit.form.TextBox(this.dijitArgs, this.parentNode);
                        break;

                    case 'org_unit':
                        this._buildOrgSelector();
                        break;

                    case 'money':
                        dojo.require('dijit.form.CurrencyTextBox');
                        this.widget = new dijit.form.CurrencyTextBox(this.dijitArgs, this.parentNode);
                        break;

                    case 'int':
                        dojo.require('dijit.form.NumberTextBox');
                        this.dijitArgs = dojo.mixin(this.dijitArgs || {}, {constraints:{places:0}});
                        this.widget = new dijit.form.NumberTextBox(this.dijitArgs, this.parentNode);
                        break;

                    case 'float':
                        dojo.require('dijit.form.NumberTextBox');
                        this.widget = new dijit.form.NumberTextBox(this.dijitArgs, this.parentNode);
                        break;

                    case 'timestamp':
                        dojo.require('dijit.form.DateTextBox');
                        dojo.require('dojo.date.stamp');
                        this.widget = new dijit.form.DateTextBox(this.dijitArgs, this.parentNode);
                        if(this.widgetValue != null) 
                            this.widgetValue = dojo.date.stamp.fromISOString(this.widgetValue);
                        break;

                    case 'bool':
                        dojo.require('dijit.form.CheckBox');
                        this.widget = new dijit.form.CheckBox(this.dijitArgs, this.parentNode);
                        this.widgetValue = openils.Util.isTrue(this.widgetValue);
                        break;

                    case 'link':
                        if(this._buildLinkSelector()) break;

                    default:
                        if(this.dijitArgs && (this.dijitArgs.required || this.dijitArgs.regExp)) {
                            dojo.require('dijit.form.ValidationTextBox');
                            this.widget = new dijit.form.ValidationTextBox(this.dijitArgs, this.parentNode);
                        } else {
                            dojo.require('dijit.form.TextBox');
                            this.widget = new dijit.form.TextBox(this.dijitArgs, this.parentNode);
                        }
                }
            }

            if(!this.async) this._widgetLoaded();
            return this.widget;
        },

        // we want to display the value for our widget.  However, instead of displaying
        // an ID, for exmaple, display the value for the 'selector' field on the object
        // the ID points to
        _tryLinkedDisplayField : function(noAsync) {

            if(this.idlField.datatype == 'org_unit')
                return false; // we already handle org_units, no need to re-fetch

            // user opted to bypass fetching this linked data
            if(this.suppressLinkedFields.indexOf(this.idlField.name) > -1)
                return false;

            var linkInfo = this._getLinkSelector();
            if(!(linkInfo && linkInfo.vfield && linkInfo.vfield.selector)) 
                return false;
            var lclass = linkInfo.linkClass;

            if(lclass == 'aou') {
                this.widgetValue = fieldmapper.aou.findOrgUnit(this.widgetValue).shortname();
                return;
            }

            // first try the store cache
            var self = this;
            if(this.cache[this.auth].list[lclass]) {
                var store = this.cache[this.auth].list[lclass];
                var query = {};
                query[linkInfo.vfield.name] = ''+this.widgetValue;
                store.fetch({query:query, onComplete:
                    function(list) {
                        self.widgetValue = store.getValue(list[0], linkInfo.vfield.selector);
                    }
                });
                return;
            }

            // then try the single object cache
            if(this.cache[this.auth].single[lclass] && this.cache[this.auth].single[lclass][this.widgetValue]) {
                this.widgetValue = this.cache[this.auth].single[lclass][this.widgetValue];
                return;
            }

            console.log("Fetching sync object " + lclass + " : " + this.widgetValue);

            // if those fail, fetch the linked object
            this.async = true;
            var self = this;
            new openils.PermaCrud().retrieve(lclass, this.widgetValue, {   
                async : !this.forceSync,
                oncomplete : function(r) {
                    var item = openils.Util.readResponse(r);
                    var newvalue = item[linkInfo.vfield.selector]();

                    if(!self.cache[self.auth].single[lclass])
                        self.cache[self.auth].single[lclass] = {};
                    self.cache[self.auth].single[lclass][self.widgetValue] = newvalue;

                    self.widgetValue = newvalue;
                    self.widget.startup();
                    self._widgetLoaded();
                }
            });
        },

        _getLinkSelector : function() {
            var linkClass = this.idlField['class'];
            if(this.idlField.reltype != 'has_a')  return false;
            if(!fieldmapper.IDL.fmclasses[linkClass].permacrud) return false;
            if(!fieldmapper.IDL.fmclasses[linkClass].permacrud.retrieve) return false;

            var vfield;
            var rclassIdl = fieldmapper.IDL.fmclasses[linkClass];

            for(var f in rclassIdl.fields) {
                if(this.idlField.key == rclassIdl.fields[f].name) {
                    vfield = rclassIdl.fields[f];
                    break;
                }
            }

            if(!vfield) 
                throw new Error("'" + linkClass + "' has no '" + this.idlField.key + "' field!");

            return {
                linkClass : linkClass,
                vfield : vfield
            };
        },

        _buildLinkSelector : function() {
            var selectorInfo = this._getLinkSelector();
            if(!selectorInfo) return false;

            var linkClass = selectorInfo.linkClass;
            var vfield = selectorInfo.vfield;

            this.async = true;

            if(linkClass == 'pgt')
                return this._buildPermGrpSelector();
            if(linkClass == 'aou')
                return this._buildOrgSelector();
            if(linkClass == 'acpl')
                return this._buildCopyLocSelector();


            dojo.require('dojo.data.ItemFileReadStore');
            dojo.require('dijit.form.FilteringSelect');

            this.widget = new dijit.form.FilteringSelect(this.dijitArgs, this.parentNode);
            this.widget.searchAttr = this.widget.labelAttr = vfield.selector || vfield.name;
            this.widget.valueAttr = vfield.name;

            var self = this;
            var oncomplete = function(list) {
                if(list) {
                    self.widget.store = 
                        new dojo.data.ItemFileReadStore({data:fieldmapper[linkClass].toStoreData(list)});
                    self.cache[self.auth].list[linkClass] = self.widget.store;
                } else {
                    self.widget.store = self.cache[self.auth].list[linkClass];
                }
                self.widget.startup();
                self._widgetLoaded();
            };

            if(this.cache[self.auth].list[linkClass]) {
                oncomplete();

            } else {
                new openils.PermaCrud().retrieveAll(linkClass, {   
                    async : !this.forceSync,
                    oncomplete : function(r) {
                        var list = openils.Util.readResponse(r, false, true);
                        oncomplete(list);
                    }
                });
            }

            return true;
        },

        /**
         * For widgets that run asynchronously, provide a callback for finishing up
         */
        _widgetLoaded : function(value) {
            
            if(this.readOnly) {

                /* -------------------------------------------------------------
                   when using widgets in a grid, the cell may dissapear, which 
                   kills the underlying DOM node, which causes this to fail.
                   For now, back out gracefully and let grid getters use
                   getDisplayString() instead
                  -------------------------------------------------------------*/
                try { 
                    this.baseWidgetValue(this.getDisplayString());
                } catch (E) {};

            } else {

                this.baseWidgetValue(this.widgetValue);
                if(this.idlField.name == this.fmIDL.pkey && this.fmIDL.pkey_sequence)
                    this.widget.attr('disabled', true); 
                if(this.disableWidgetTest && this.disableWidgetTest(this.idlField.name, this.fmObject))
                    this.widget.attr('disabled', true); 
            }
            if(this.onload)
                this.onload(this.widget, this);
        },

        _buildOrgSelector : function() {
            dojo.require('fieldmapper.OrgUtils');
            dojo.require('openils.widget.FilteringTreeSelect');
            this.widget = new openils.widget.FilteringTreeSelect(this.dijitArgs, this.parentNode);
            this.widget.searchAttr = 'shortname';
            this.widget.labelAttr = 'shortname';
            this.widget.parentField = 'parent_ou';
            var user = new openils.User();

            if(this.widgetValue == null) 
                this.widgetValue = user.user.ws_ou();
            
            // if we have a limit perm, find the relevent orgs (async)
            if(this.orgLimitPerms && this.orgLimitPerms.length > 0) {
                this.async = true;
                var self = this;
                user.getPermOrgList(this.orgLimitPerms, 
                    function(orgList) {
                        self.widget.tree = orgList;
                        self.widget.startup();
                        self._widgetLoaded();
                    }
                );

            } else {
                this.widget.tree = fieldmapper.aou.globalOrgTree;
                this.widget.startup();
            }
        },

        _buildPermGrpSelector : function() {
            dojo.require('openils.widget.FilteringTreeSelect');
            this.widget = new openils.widget.FilteringTreeSelect(this.dijitArgs, this.parentNode);
            this.widget.searchAttr = 'name';

            if(this.cache.permGrpTree) {
                this.widget.tree = this.cache.permGrpTree;
                this.widget.startup();
                return true;
            } 

            var self = this;
            this.async = true;
            new openils.PermaCrud().retrieveAll('pgt', {
                async : !this.forceSync,
                oncomplete : function(r) {
                    var list = openils.Util.readResponse(r, false, true);
                    if(!list) return;
                    var map = {};
                    var root = null;
                    for(var l in list)
                        map[list[l].id()] = list[l];
                    for(var l in list) {
                        var node = list[l];
                        var pnode = map[node.parent()];
                        if(!pnode) {root = node; continue;}
                        if(!pnode.children()) pnode.children([]);
                        pnode.children().push(node);
                    }
                    self.widget.tree = self.cache.permGrpTree = root;
                    self.widget.startup();
                    self._widgetLoaded();
                }
            });

            return true;
        },

        _buildCopyLocSelector : function() {
            dojo.require('dijit.form.FilteringSelect');
            this.widget = new dijit.form.FilteringSelect(this.dijitArgs, this.parentNode);
            this.widget.searchAttr = this.widget.labalAttr = 'name';
            this.widget.valueAttr = 'id';

            if(this.cache.copyLocStore) {
                this.widget.store = this.cache.copyLocStore;
                this.widget.startup();
                this.async = false;
                return true;
            } 

            // my orgs
            var ws_ou = openils.User.user.ws_ou();
            var orgs = fieldmapper.aou.findOrgUnit(ws_ou).orgNodeTrail().map(function (i) { return i.id() });
            orgs = orgs.concat(fieldmapper.aou.descendantNodeList(ws_ou).map(function (i) { return i.id() }));

            var self = this;
            new openils.PermaCrud().search('acpl', {owning_lib : orgs}, {
                async : !this.forceSync,
                oncomplete : function(r) {
                    var list = openils.Util.readResponse(r, false, true);
                    if(!list) return;
                    self.widget.store = 
                        new dojo.data.ItemFileReadStore({data:fieldmapper.acpl.toStoreData(list)});
                    self.cache.copyLocStore = self.widget.store;
                    self.widget.startup();
                    self._widgetLoaded();
                }
            });

            return true;
        }
    });

    openils.widget.AutoFieldWidget.localeStrings = dojo.i18n.getLocalization("openils.widget", "AutoFieldWidget");
    openils.widget.AutoFieldWidget.cache = {};
}

