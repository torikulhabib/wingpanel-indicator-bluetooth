/*
 * Copyright 2021 elementary, Inc. (https://elementary.io)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA
 *
 * Authored by: Torikulhabib <torik.habib@gamail.com>
 *
 */

public class BtSender : Granite.Dialog {
    public Bluetooth.Obex.Transfer transfer;
    public Bluetooth.Device device;
    private Gtk.ProgressBar progressbar;
    private Gtk.Label path_label;
    private Gtk.Label device_label;
    private Gtk.Label progress_label;
    private Gtk.Label filename_label;
    private Gtk.Label rate_label;
    private Gtk.Image icon_label;
    private Gtk.ListStore liststore;
    private BtRetry bt_retry = null;
    private int start_time = 0;
    private int current_file = 0;
    private int total_file = 0;
    private uint64 total_size = 0;
    private GLib.ObjectPath s_session;
    private GLib.File file_path;
    private GLib.DBusConnection connection;
    private GLib.DBusProxy client_proxy;
    private GLib.DBusProxy session;

    public BtSender (Gtk.Application application) {
        Object (
            application: application,
            resizable :false
        );
    }

    construct {
        liststore = new Gtk.ListStore (1, typeof (File));

        var icon_image = new Gtk.Image.from_icon_name ("bluetooth", Gtk.IconSize.DIALOG) {
            valign = Gtk.Align.END,
            halign = Gtk.Align.END
        };

        icon_label = new Gtk.Image () {
            halign = Gtk.Align.END,
            valign = Gtk.Align.END
        };

        var overlay = new Gtk.Overlay ();
        overlay.add (icon_image);
        overlay.add_overlay (icon_label);

        path_label = new Gtk.Label ("<b>From</b>:") {
            max_width_chars = 45,
            use_markup = true,
            wrap = true,
            xalign = 0
        };
        path_label.get_style_context ().add_class ("primary");

        device_label = new Gtk.Label ("<b>To</b>:") {
            max_width_chars = 45,
            use_markup = true,
            wrap = true,
            xalign = 0
        };
        filename_label = new Gtk.Label ("<b>Filename</b>:") {
            max_width_chars = 45,
            use_markup = true,
            wrap = true,
            xalign = 0
        };
        rate_label = new Gtk.Label ("<b>Transfer rate:</b>") {
            max_width_chars = 45,
            use_markup = true,
            wrap = true,
            xalign = 0
        };
        progressbar = new Gtk.ProgressBar () {
            hexpand = true
        };
        progress_label = new Gtk.Label (null) {
            max_width_chars = 45,
            hexpand = false,
            wrap = true,
            xalign = 0
        };
        var message_grid = new Gtk.Grid () {
            column_spacing = 0,
            width_request = 450,
            margin_start = 10,
            margin_end = 15
        };
        message_grid.attach (overlay, 0, 0, 1, 3);
        message_grid.attach (path_label, 1, 0, 1, 1);
        message_grid.attach (device_label, 1, 1, 1, 1);
        message_grid.attach (filename_label, 1, 2, 1, 1);
        message_grid.attach (rate_label, 1, 3, 1, 1);
        message_grid.attach (progressbar, 1, 4, 1, 1);
        message_grid.attach (progress_label, 1, 5, 1, 1);
        get_content_area ().add (message_grid);

        add_button ("Close", Gtk.ResponseType.CLOSE);
        var reject_transfer = add_button ("Cancel", Gtk.ResponseType.CANCEL);
        reject_transfer.get_style_context ().add_class (Gtk.STYLE_CLASS_DESTRUCTIVE_ACTION);

        response.connect ((response_id) => {
            if (response_id == Gtk.ResponseType.CANCEL) {
                if (transfer != null) {
                    if (transfer.status == "active") {
                        try {
                            transfer.cancel ();
                        } catch (Error e) {
                            GLib.warning (e.message);
                        }

                        remove_session.begin ();
                    }
                }

                destroy ();
            } else {
                if (transfer.status == "active") {
                    hide_on_delete ();
                } else {
                    destroy ();
                }
            }
        });

        delete_event.connect (() => {
            if (transfer.status == "active") {
                return hide_on_delete ();
            } else {
                return false;
            }
        });
    }

    public void add_files (File [] files, Bluetooth.Device device) {
        foreach (var file in files) {
            Gtk.TreeIter iter;
            liststore.append (out iter);
            liststore.set (iter, 0, file);
        }

        this.device = device;

        Gtk.TreeIter iter;
        liststore.get_iter_first (out iter);
        liststore.get (iter, 0, out file_path);

        total_n_current ();
        create_season.begin ();
    }

    public void insert_files (File [] files) {
        foreach (var file in files) {
            bool exist = false;
            liststore.foreach ((model, path, iter) => {
                File filename;
                model.get (iter, 0, out filename);
                    if (filename == file) {
                        exist = true;
                    }

                    return false;
            });

            if (exist) {
                return;
            }

            Gtk.TreeIter iter;
            liststore.append (out iter);
            liststore.set (iter, 0, file);
            total_n_current (true);
        }
    }

    private bool next_file () {
        Gtk.TreeIter iter;
        if (liststore.get_iter_from_string (out iter, current_file.to_string ())) {
            liststore.get (iter, 0, out file_path);
            send_file.begin ();
            total_n_current ();
            return true;
        }

        return false;
    }
    private void total_n_current (bool total = false) {
        total_file = 0;
        int current = 0;
        liststore.foreach ((model, path, iter) => {
            File file;
            model.get (iter, 0, out file);
            if (file == file_path) {
                current = total_file;
            }

            total_file++;
            return false;
        });

        if (!total) {
            current_file = current + 1;
        }
    }

    private async void create_season () {
        try {
            connection = yield GLib.Bus.get (BusType.SESSION);
            client_proxy = yield new GLib.DBusProxy (
                connection,
                GLib.DBusProxyFlags.DO_NOT_LOAD_PROPERTIES | GLib.DBusProxyFlags.DO_NOT_CONNECT_SIGNALS,
                null,
                "org.bluez.obex",
                "/org/bluez/obex",
                "org.bluez.obex.Client1"
            );
            VariantBuilder builder = new VariantBuilder (VariantType.DICTIONARY);
            builder.add ("{sv}", "Target", new Variant.string ("opp"));
            Variant parameters = new Variant ("(sa{sv})", device.address, builder);
            Variant variant_client = yield client_proxy.call ("CreateSession", parameters, GLib.DBusCallFlags.NONE, -1);
            variant_client.get ("(o)", out s_session);
            session = yield new GLib.DBusProxy (
                connection,
                GLib.DBusProxyFlags.NONE,
                null,
                "org.bluez.obex",
                s_session,
                "org.bluez.obex.ObjectPush1"
            );
            send_file.begin ();
        } catch (Error e) {
            GLib.warning (e.message);
        }
    }

    private async void remove_session () {
        try {
            yield client_proxy.call ("RemoveSession", new Variant ("(o)", s_session), GLib.DBusCallFlags.NONE, -1);
        } catch (Error e) {
            GLib.warning (e.message);
        }
    }

    private async void send_file () {
        path_label.set_markup (_("<b>From</b>: %s").printf (file_path.get_parent ().get_path ()));
        device_label.set_markup (_("<b>To</b>: %s").printf (GLib.Markup.escape_text (device.name)));
        icon_label.set_from_gicon (
            new ThemedIcon (device.icon == null? "bluetooth" : device.icon), Gtk.IconSize.LARGE_TOOLBAR
        );
        progress_label.label = _("Sending… (%i/%i)").printf (current_file, total_file);
        try {
            Variant variant = yield session.call (
                "SendFile", new Variant ("(s)", file_path.get_path ()), GLib.DBusCallFlags.NONE, -1
            );
            start_time = (int) get_real_time ();
            GLib.ObjectPath objectpath;
            variant.get ("(oa{sv})", out objectpath, null);
            transfer = Bus.get_proxy_sync (BusType.SESSION, "org.bluez.obex", objectpath);
            filename_label.set_markup (_("<b>Filename</b>: %s").printf (
                GLib.Markup.escape_text (transfer.name))
            );
            total_size = transfer.size;
            ((DBusProxy) transfer).g_properties_changed.connect ((changed, invalid) => {
                tranfer_progress ();
            });
        } catch (Error e) {
            GLib.warning (e.message);
        }
    }

    private void tranfer_progress () {
        switch (transfer.status) {
            case "error":
                if (bt_retry == null) {
                    hide_on_delete ();
                    bt_retry = new BtRetry (this);
                    bt_retry.update_device (device.name);
                    bt_retry.update_filename (file_path.get_basename ());
                    bt_retry.update_result (device.name);
                    bt_retry.show_all ();

                    bt_retry.response.connect ((response_id) => {
                        if (response_id == Gtk.ResponseType.ACCEPT) {
                            create_season.begin ();
                            present ();
                            bt_retry.destroy ();
                        } else {
                            destroy ();
                        }
                    });

                    bt_retry.destroy.connect (()=> {
                        bt_retry = null;
                    });
                }

                progressbar.fraction = 0.0;
                remove_session.begin ();
                break;
            case "queued":
                break;
            case "active":
                on_transfer_progress (transfer.transferred);
                break;
            case "complete":
                send_notify ();
                if (!next_file ()) {
                    remove_session.begin ();
                    destroy ();
                }

                break;
        }
    }

    private void send_notify () {
        var notification = new GLib.Notification ("bluetooth");
        notification.set_icon (new ThemedIcon (device.icon));
        notification.set_priority (NotificationPriority.NORMAL);
        notification.set_title (_("File transferred successfully "));
        notification.set_body (_("<b>From:</b> %s <b>Send to:</b> %s").printf (file_path.get_path (), device.name));
        ((Gtk.Window)get_toplevel ()).application.send_notification ("io.elementary.bluetooth", notification);
    }

    private void on_transfer_progress (uint64 transferred) {
        progressbar.fraction = (double) transferred / (double) total_size;
        int current_time = (int) get_real_time ();
        int elapsed_time = (current_time - start_time) / 1000000;
        if (current_time < start_time + 1000000) {
            return;
        }

        if (elapsed_time == 0) {
            return;
        }

        uint64 transfer_rate = transferred / elapsed_time;
        if (transfer_rate == 0) {
            return;
        }

        rate_label.label = _("<b>Transfer rate:</b> %s").printf (GLib.format_size (transfer_rate));
        uint64 remaining_time = (total_size - transferred) / transfer_rate;
        progress_label.label = _("(%i/%i) %s of %s sent, time remaining %s").printf (
            current_file,
            total_file,
            GLib.format_size (transferred),
            GLib.format_size (total_size),
            format_time ((int)remaining_time)
        );
    }

    private string format_time (int seconds) {
        if (seconds < 0) {
            seconds = 0;
        }

        if (seconds < 60) {
            return ngettext ("%'d second", "%'d seconds", seconds).printf (seconds);
        }

        int minutes;
        if (seconds < 60 * 60) {
            minutes = (seconds + 30) / 60;
            return ngettext ("%'d minute", "%'d minutes", minutes).printf (minutes);
        }

        int hours = seconds / (60 * 60);
        if (seconds < 60 * 60 * 4) {
            minutes = (seconds - hours * 60 * 60 + 30) / 60;
            string h = ngettext ("%'u hour", "%'u hours", hours).printf (hours);
            string m = ngettext ("%'u minute", "%'u minutes", minutes).printf (minutes);
            return h.concat (", ", m);
        }

        return ngettext ("approximately %'d hour", "approximately %'d hours", hours).printf (hours);
    }
}
