//  
//  Copyright (C) 2011 Robert Dyer, Michal Hruby, Rico Tzschichholz
// 
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
// 
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
// 
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
// 

using Cairo;
using Gdk;
using Gee;
using Gtk;

using Plank.Items;
using Plank.Drawing;
using Plank.Factories;
using Plank.Services.Windows;

namespace Plank.Widgets
{
	public enum DockPosition
	{
		BOTTOM,
		TOP,
		LEFT,
		RIGHT
	}
	
	public class DockWindow : CompositedWindow
	{
		public DockPreferences Prefs { get; protected set; }
		
		public DockItem? HoveredItem { get; protected set; }
		
		public DockItems Items { get; protected set; }
		
		public DockRenderer Renderer { get; protected set; }
		
		
		protected HoverWindow hover = new HoverWindow ();

		protected HideManager hide_manager;
		
		protected Menu menu = new Menu ();
		
		
		protected Gdk.Rectangle monitor_geo;
		
		public int win_x { get; protected set; }
		public int win_y { get; protected set; }
		
		uint reposition_timer = 0;
		
		bool dock_is_starting = true;
		
		
		public DockWindow ()
		{
			base ();
			
			Prefs = new DockPreferences.with_file ("settings");
			Items = new DockItems ();
			Renderer = new DockRenderer (this);
			hide_manager = new HideManager (this);
			
			set_accept_focus (false);
			can_focus = false;
			skip_pager_hint = true;
			skip_taskbar_hint = true;
			set_type_hint (WindowTypeHint.DOCK);
			
			menu.attach_to_widget (this, null);
			menu.show.connect (update_icon_regions);
			menu.hide.connect (on_menu_hide);
			
			stick ();
			
			add_events (EventMask.BUTTON_PRESS_MASK |
						EventMask.BUTTON_RELEASE_MASK |
						EventMask.ENTER_NOTIFY_MASK |
						EventMask.LEAVE_NOTIFY_MASK |
						EventMask.POINTER_MOTION_MASK |
						EventMask.SCROLL_MASK);
			
			Items.item_added.connect (set_size);
			Items.item_removed.connect (set_size);
			Prefs.notify.connect (set_size);
			Renderer.notify["Hidden"].connect (update_icon_regions);
			
			get_screen ().size_changed.connect (update_monitor_geo);
			get_screen ().monitors_changed.connect (update_monitor_geo);
			
			int x, y;
			get_position (out x, out y);
			win_x = x;
			win_y = y;
			
			update_monitor_geo ();
		}
		
		~DockWindow ()
		{
			menu.show.disconnect (update_icon_regions);
			menu.hide.disconnect (on_menu_hide);
			
			Items.item_added.disconnect (set_size);
			Items.item_removed.disconnect (set_size);
			Prefs.notify.disconnect (set_size);
			Renderer.notify["Hidden"].disconnect (update_icon_regions);
			
			get_screen ().size_changed.disconnect (update_monitor_geo);
			get_screen ().monitors_changed.disconnect (update_monitor_geo);
		}
		
		public override bool button_press_event (EventButton event)
		{
			if (HoveredItem == null)
				return true;
			
			var button = PopupButton.from_event_button (event);
			if ((event.state & ModifierType.CONTROL_MASK) == ModifierType.CONTROL_MASK
					&& (button & PopupButton.RIGHT) == PopupButton.RIGHT)
				do_popup (event.button, true);
			else if ((HoveredItem.Button & button) == button)
				do_popup (event.button, false);
			
			return true;
		}
		
		public override bool button_release_event (EventButton event)
		{
			if (HoveredItem != null && !menu_is_visible ())
				HoveredItem.clicked (PopupButton.from_event_button (event), event.state);
			
			return true;
		}
		
		public override bool enter_notify_event (EventCrossing event)
		{
			update_hovered ((int) event.x, (int) event.y);
			
			return true;
		}
		
		public override bool leave_notify_event (EventCrossing event)
		{
			if (!menu_is_visible ())
				set_hovered (null);
			else
				hover.hide ();
			
			return true;
		}
		
		public override bool motion_notify_event (EventMotion event)
		{
			if (update_hovered ((int) event.x, (int) event.y))
				return true;
			
			set_hovered (null);
			return true;
		}
		
		public override bool scroll_event (EventScroll event)
		{
			if ((event.state & ModifierType.CONTROL_MASK) != 0) {
				if (event.direction == ScrollDirection.UP)
					Prefs.increase_icon_size ();
				else if (event.direction == ScrollDirection.DOWN)
					Prefs.decrease_icon_size ();
				
				return true;
			}
			
			if (HoveredItem != null)
				HoveredItem.scrolled (event.direction, event.state);
			
			return true;
		}
		
		public override bool expose_event (EventExpose event)
		{
			if (dock_is_starting) {
				Services.Logger.debug<DockWindow> ("dock window loaded");
				dock_is_starting = false;
				
				// slide the dock in, if it shouldnt start hidden
				GLib.Timeout.add (400, () => {
					hide_manager.update_dock_hovered ();
					return false;
				});
			}
			
			set_input_mask ();
			Renderer.draw_dock (cairo_create (event.window));
			
			return true;
		}
		
		protected void set_hovered (DockItem? item)
		{
			if (HoveredItem == item)
				return;
			
			HoveredItem = item;
			
			if (HoveredItem == null) {
				hover.hide ();
				return;
			}
			
			if (hover.get_visible ())
				hover.hide ();
			
			hover.Text = HoveredItem.Text;
			position_hover ();
			
			if (!hover.get_visible ())
				hover.show ();
		}
		
		protected bool update_hovered (int x, int y)
		{
			foreach (var item in Items.Items) {
				var rect = Renderer.item_hover_region (item);
				
				if (y >= rect.y && y <= rect.y + rect.height && x >= rect.x && x <= rect.x + rect.width) {
					set_hovered (item);
					return true;
				}
			}
			
			return false;
		}
		
		protected void update_monitor_geo ()
		{
			var screen = get_screen ();
			var monitor = screen.get_monitor_at_point (win_x, win_y);
			
			screen.get_monitor_geometry (monitor, out monitor_geo);
			
			set_size ();
		}
		
		protected void position_hover ()
		{
			var rect = Renderer.item_hover_region (HoveredItem);
			hover.move_hover (win_x + rect.x + rect.width / 2, win_y + rect.y);
		}
		
		public void set_size ()
		{
			set_size_request (Renderer.DockWidth, Renderer.DockHeight);
			reposition ();
			if (HoveredItem != null)
				position_hover ();
			
			Renderer.reset_buffers ();
		}
		
		protected void reposition ()
		{
			if (reposition_timer != 0) {
				GLib.Source.remove (reposition_timer);
				reposition_timer = 0;
			}
			
			reposition_timer = GLib.Timeout.add (50, () => {
				reposition_timer = 0;
				
				// put dock on bottom-center of monitor
				win_x = monitor_geo.x + (monitor_geo.width - width_request) / 2;
				win_y = monitor_geo.y + monitor_geo.height - height_request;
				move (win_x, win_y);
				
				update_icon_regions ();
				set_struts ();
				set_hovered (null);
				
				return false;
			});
		}
		
		protected void update_icon_regions ()
		{
			foreach (var item in Items.Items) {
				unowned ApplicationDockItem appitem = (item as ApplicationDockItem);
				if (appitem == null || appitem.App == null)
					continue;
				
				if (menu_is_visible () || Renderer.Hidden)
					WindowControl.update_icon_regions (appitem.App, null, win_x, win_y);
				else
					WindowControl.update_icon_regions (appitem.App, Renderer.item_hover_region (appitem), win_x, win_y);
			}
			
			Renderer.animated_draw ();
		}
		
		public bool menu_is_visible ()
		{
			return menu.get_visible ();
		}
		
		protected void do_popup (uint button, bool show_plank_menu)
		{
			foreach (var w in menu.get_children ()) {
				menu.remove (w);
				if (w is ImageMenuItem)
					(w as ImageMenuItem).get_image ().destroy ();
				w.destroy ();
			}
			
			ArrayList<MenuItem> items;
			if (show_plank_menu)
				items = PlankDockItem.get_plank_menu_items ();
			else
				items = HoveredItem.get_menu_items ();
			
			if (items.size == 0)
				return;
			
			foreach (var item in items)
				menu.append (item);
			
			menu.show_all ();
			if (show_plank_menu)
				menu.popup (null, null, null, button, get_current_event_time ());
			else
				menu.popup (null, null, position_menu, button, get_current_event_time ());
		}
		
		protected void on_menu_hide ()
		{
			hide_manager.update_dock_hovered ();
			if (!hide_manager.DockHovered)
				set_hovered (null);
		}
		
		protected void position_menu (Menu menu, out int x, out int y, out bool push_in)
		{
			var rect = Renderer.item_hover_region (HoveredItem);
			
			x = win_x + rect.x + rect.width / 2 - menu.requisition.width / 2;
			y = win_y + rect.y - menu.requisition.height - 10;
			push_in = false;
		}
		
		private void set_input_mask ()
		{
			if (!is_realized ())
				return;
			
			var offset = (int) double.max (1, (1 - Renderer.HideOffset) * Renderer.VisibleDockHeight);
			var pixmap = new Pixmap (null, Renderer.VisibleDockWidth, offset, 1);
			var cr = cairo_create (pixmap);
			
			cr.set_source_rgba (0, 0, 0, 1);
			cr.paint ();
			
			input_shape_combine_mask ((Bitmap*) pixmap, (width_request - Renderer.VisibleDockWidth) / 2, height_request - offset);
		}
		
		protected enum Struts 
		{
			LEFT,
			RIGHT,
			TOP,
			BOTTOM,
			LEFT_START,
			LEFT_END,
			RIGHT_START,
			RIGHT_END,
			TOP_START,
			TOP_END,
			BOTTOM_START,
			BOTTOM_END,
			N_VALUES
		}
		
		private void set_struts ()
		{
			if (!is_realized ())
				return;
			
			var struts = new ulong [Struts.N_VALUES];
			
			if (Prefs.HideMode == HideType.NONE) {
				struts [Struts.BOTTOM] = Renderer.VisibleDockHeight + get_screen ().get_height () - monitor_geo.y - monitor_geo.height;
				struts [Struts.BOTTOM_START] = monitor_geo.x;
				struts [Struts.BOTTOM_END] = monitor_geo.x + monitor_geo.width - 1;
			}
			
			var first_struts = new ulong [Struts.BOTTOM + 1];
			for (var i = 0; i < first_struts.length; i++)
				first_struts [i] = struts [i];
			
			var display = x11_drawable_get_xdisplay (get_window ());
			var xid = x11_drawable_get_xid (get_window ());
			
			display.change_property (xid, display.intern_atom ("_NET_WM_STRUT_PARTIAL", false), X.XA_CARDINAL,
			                      32, X.PropMode.Replace, (uchar[]) struts, struts.length);
			display.change_property (xid, display.intern_atom ("_NET_WM_STRUT", false), X.XA_CARDINAL, 
			                      32, X.PropMode.Replace, (uchar[]) first_struts, first_struts.length);
		}
	}
}