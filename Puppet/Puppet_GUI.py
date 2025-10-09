###############################
# VM Fact Finder GUI
# -------------------
# This script provides a graphical user interface (GUI) to search for
# Virtual Machine (VM) facts and Puppet profile-related data.
#
# Features:
# - Fetches VM facts from a Puppetboard API endpoint.
# - Extracts relevant Puppet facts such as fqdn, domain, function, ipaddress, windows_product_name, and site.
# - Lists all VMs related to a specific Puppet profile by scanning local Hiera YAML files and Puppet manifests.
# - Displays matching nodes with a given Puppet function.
# - Supports searching by VM FQDN or Puppet profile name.
# - Provides interactive lists for browsing VMs, YAML files, and manifests.
#
# Requirements:
# - Python 3.x
# - Requests library
# - BeautifulSoup4 library
#
# Usage:
# - Configure the BASE_URL, DRIVE_LETTER, and GIT_USERNAME in the CONFIG section below.
# - Run the script, enter a VM FQDN or profile name, and explore the Puppet facts.
#
# Author: Oskar Dlugolecki
###############################

import os
import re
import glob
import json
import requests
import urllib3
import tkinter as tk
from tkinter import ttk, simpledialog, messagebox, scrolledtext
from bs4 import BeautifulSoup

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- CONFIG SECTION ---

# Puppetboard base URL (replace with your actual URL)
BASE_URL = "https://puppetboard.example.com"  # <-- Replace with your Puppetboard URL

# Paths (adjust as needed)
DRIVE_LETTER = 'D:'  # e.g. 'D:' or 'C:'
GIT_USERNAME = 'your_username'  # <-- Replace with your git username or folder name

# Keys to extract from Puppet facts
FILTER_KEYS = [
    "fqdn",
    "domain",
    "function",
    "ipaddress",
    "windows_product_name",
    "site"
]

# --- END CONFIG SECTION ---


def get_paths():
    # Constructs local paths based on config variables
    gui_path = os.path.join(DRIVE_LETTER + os.sep, 'Git', GIT_USERNAME, 'mgt-puppet-control', 'GUI')
    hiera_path = os.path.join(DRIVE_LETTER + os.sep, 'Git', GIT_USERNAME, 'mgt-puppet-control', 'data', 'nodes')
    manifest_root = os.path.join(DRIVE_LETTER + os.sep, 'Git', GIT_USERNAME, 'mgt-puppet-control', 'site-modules', 'role', 'manifests')
    return gui_path, hiera_path, manifest_root


def fetch_and_extract(fqdn):
    dt_url = f"{BASE_URL}/*/node/{fqdn}/facts/json"
    api_url = f"{BASE_URL}/api/v1/facts"
    params = {"certname": fqdn}
    try:
        r = requests.get(dt_url, verify=False, timeout=10)
        r.raise_for_status()
        raw = r.json()
    except Exception:
        r = requests.get(api_url, params=params, verify=False, timeout=10)
        r.raise_for_status()
        raw = r.json()
    rows = raw.get('data') if isinstance(raw, dict) and 'data' in raw else raw
    extracted = {key: '<not found>' for key in FILTER_KEYS}
    for entry in rows:
        if isinstance(entry, dict):
            name = entry.get('name', '').lower()
            value = entry.get('value', '')
        elif isinstance(entry, (list, tuple)) and len(entry) >= 2:
            name = entry[0].lower(); raw_val = entry[1]
            try:
                parsed = json.loads(raw_val)
                value = parsed[1]
            except Exception:
                value = raw_val
        else:
            continue
        for key in FILTER_KEYS:
            if key == 'ipaddress':
                if (name == 'ipaddress' or name.startswith('ipaddress_')) and not name.startswith('ipaddress6_'):
                    if extracted[key] == '<not found>': extracted[key] = value
                continue
            if name == key or name.startswith(key + '_'):
                extracted[key] = value; break
    return extracted


def fetch_nodes_for_function(function_name):
    encoded = requests.utils.quote(f'"{function_name}"', safe='')
    json_url = f"{BASE_URL}/*/fact/function/{encoded}/json"
    resp = requests.get(json_url, verify=False, timeout=10)
    resp.raise_for_status(); raw = resp.json()
    rows = raw.get('data') if isinstance(raw, dict) and 'data' in raw else raw
    nodes = set()
    for entry in rows:
        if isinstance(entry, list) and entry:
            soup = BeautifulSoup(entry[0], 'html.parser'); a = soup.find('a')
            if a: nodes.add(a.get_text(strip=True))
        elif isinstance(entry, dict) and 'certname' in entry:
            nodes.add(entry['certname'])
    return sorted(nodes)


class ProfileResultsWindow(tk.Toplevel):
    def __init__(self, parent, profile_name):
        super().__init__(parent)
        self.title(f"VMs & files for profile '{profile_name}'")
        self.geometry("900x600")

        _, hiera_path, manifest_root = get_paths()
        yaml_matches = []
        for yfile in glob.glob(os.path.join(hiera_path, '*.yaml')):
            try:
                with open(yfile, 'r') as yh:
                    if profile_name in yh.read(): yaml_matches.append(os.path.basename(yfile))
            except: pass
        pp_matches = []
        for pfile in glob.glob(os.path.join(manifest_root, '**', '*.pp'), recursive=True):
            try:
                with open(pfile, 'r') as mf:
                    if profile_name in mf.read(): pp_matches.append(os.path.splitext(os.path.basename(pfile))[0])
            except: pass
        combined_vms = set(os.path.splitext(y)[0] for y in yaml_matches)
        for func in pp_matches:
            func_name = f"windows_{func}"
            try:
                combined_vms.update(fetch_nodes_for_function(func_name))
            except: pass

        main_pane = tk.PanedWindow(self, orient=tk.HORIZONTAL); main_pane.pack(fill='both', expand=True)
        vm_frame = tk.LabelFrame(main_pane, text="All VMs for profile")
        scroll_v = tk.Scrollbar(vm_frame, orient='vertical')
        self.vm_list = tk.Listbox(vm_frame, yscrollcommand=scroll_v.set)
        scroll_v.config(command=self.vm_list.yview); scroll_v.pack(side='right', fill='y')
        self.vm_list.pack(side='left', fill='both', expand=True)
        for vm in sorted(combined_vms): self.vm_list.insert('end', vm)
        main_pane.add(vm_frame)

        right_pane = tk.PanedWindow(main_pane, orient=tk.VERTICAL); main_pane.add(right_pane)
        yaml_frame = tk.LabelFrame(right_pane, text="Matching Hiera YAML files")
        scroll_y = tk.Scrollbar(yaml_frame, orient='vertical')
        self.yaml_list = tk.Listbox(yaml_frame, yscrollcommand=scroll_y.set)
        scroll_y.config(command=self.yaml_list.yview); scroll_y.pack(side='right', fill='y')
        self.yaml_list.pack(side='left', fill='both', expand=True)
        for yf in yaml_matches: self.yaml_list.insert('end', yf)
        right_pane.add(yaml_frame)

        pp_frame = tk.LabelFrame(right_pane, text="Matching role manifests (functions)\n(Double-click to see its VMs)")
        scroll_p = tk.Scrollbar(pp_frame, orient='vertical')
        self.pp_list = tk.Listbox(pp_frame, yscrollcommand=scroll_p.set)
        scroll_p.config(command=self.pp_list.yview); scroll_p.pack(side='right', fill='y')
        self.pp_list.pack(side='left', fill='both', expand=True)
        for func in pp_matches: self.pp_list.insert('end', f"windows_{func}")
        self.pp_list.bind('<Double-Button-1>', self.on_pp_double)
        right_pane.add(pp_frame)

    def on_pp_double(self, event):
        sel = self.pp_list.curselection()
        if sel: FunctionResultsWindow(self, self.pp_list.get(sel[0]))


class FunctionResultsWindow(tk.Toplevel):
    def __init__(self, parent, function_name):
        super().__init__(parent)
        self.title(f"VMs for function '{function_name}'")
        self.geometry("700x500")
        nodes = fetch_nodes_for_function(function_name)
        pane = tk.PanedWindow(self, orient=tk.VERTICAL); pane.pack(fill='both', expand=True)
        nodes_frame = tk.LabelFrame(pane, text=f"Nodes with function '{function_name}'")
        scroll_n = tk.Scrollbar(nodes_frame, orient='vertical')
        list_n = tk.Listbox(nodes_frame, yscrollcommand=scroll_n.set)
        scroll_n.config(command=list_n.yview); scroll_n.pack(side='right', fill='y')
        list_n.pack(side='left', fill='both', expand=True)
        for n in nodes: list_n.insert('end', n)
        pane.add(nodes_frame)


class ResultsWindow(tk.Toplevel):
    def __init__(self, parent, fqdn, facts):
        super().__init__(parent)
        self.title(f"VM Facts for {fqdn}")
        self.geometry("1000x800")

        _, hiera_path, manifest_root = get_paths()

        ctrl = tk.Frame(self)
        ctrl.pack(fill='x', pady=5)
        tk.Button(ctrl, text="New Search", command=self.new_search).pack(side='left', padx=5)
        tk.Button(ctrl, text="Clear", command=self.clear_all).pack(side='left')

        main_pane = tk.PanedWindow(self, orient=tk.HORIZONTAL)
        main_pane.pack(fill='both', expand=True)

        left_frame = tk.Frame(main_pane)
        facts_frame = tk.LabelFrame(left_frame, text="Facts")
        facts_frame.pack(fill='x', padx=10, pady=5)
        self.tree = ttk.Treeview(facts_frame, columns=('Fact','Value'), show='headings', height=6)
        for col in ('Fact','Value'):
            self.tree.heading(col, text=col)
            self.tree.column(col, width=300)
        self.tree.pack(fill='x', padx=5, pady=5)
        self.insert_facts(facts)

        self.func = facts.get('function')
        if self.func and self.func != '<not found>':
            nodes = fetch_nodes_for_function(self.func)
            nodes_frame = tk.LabelFrame(left_frame, text=f"Nodes with function '{self.func}'")
            nodes_frame.pack(fill='both', expand=True, padx=10, pady=5)
            tk.Label(nodes_frame, text="Double-click a node below for new search").pack(anchor='nw', padx=5)
            scroll = tk.Scrollbar(nodes_frame, orient='vertical')
            self.nodes_list = tk.Listbox(nodes_frame, yscrollcommand=scroll.set)
            scroll.config(command=self.nodes_list.yview)
            scroll.pack(side='right', fill='y')
            self.nodes_list.pack(side='left', fill='both', expand=True, padx=5, pady=5)
            self.nodes_list.bind('<Double-Button-1>', self.on_node_double_click)
            for n in nodes:
                self.nodes_list.insert(tk.END, n)

        main_pane.add(left_frame)

        right_pane = tk.PanedWindow(main_pane, orient=tk.VERTICAL)
        main_pane.add(right_pane)

        yaml_frame = tk.LabelFrame(right_pane, text="Matching Hiera YAML files")
        scroll_y = tk.Scrollbar(yaml_frame, orient='vertical')
        self.yaml_list = tk.Listbox(yaml_frame, yscrollcommand=scroll_y.set)
        scroll_y.config(command=self.yaml_list.yview)
        scroll_y.pack(side='right', fill='y')
        self.yaml_list.pack(side='left', fill='both', expand=True)
        yaml_files = []
        try:
            for yfile in glob.glob(os.path.join(hiera_path, '*.yaml')):
                with open(yfile, 'r') as f:
                    if fqdn in f.read():
                        yaml_files.append(os.path.basename(yfile))
        except Exception:
            pass
        for yf in sorted(yaml_files):
            self.yaml_list.insert('end', yf)

        right_pane.add(yaml_frame)

        pp_frame = tk.LabelFrame(right_pane, text="Matching role manifests (functions)\n(Double-click to see its VMs)")
        scroll_p = tk.Scrollbar(pp_frame, orient='vertical')
        self.pp_list = tk.Listbox(pp_frame, yscrollcommand=scroll_p.set)
        scroll_p.config(command=self.pp_list.yview)
        scroll_p.pack(side='right', fill='y')
        self.pp_list.pack(side='left', fill='both', expand=True)
        pp_files = []
        try:
            for pfile in glob.glob(os.path.join(manifest_root, '**', '*.pp'), recursive=True):
                with open(pfile, 'r') as f:
                    if fqdn in f.read():
                        pp_files.append(os.path.splitext(os.path.basename(pfile))[0])
        except Exception:
            pass
        for pf in sorted(pp_files):
            self.pp_list.insert('end', f"windows_{pf}")
        self.pp_list.bind('<Double-Button-1>', self.on_pp_double)

        right_pane.add(pp_frame)

    def insert_facts(self, facts):
        for key, value in facts.items():
            self.tree.insert('', 'end', values=(key, value))

    def on_node_double_click(self, event):
        sel = self.nodes_list.curselection()
        if sel:
            fqdn = self.nodes_list.get(sel[0])
            facts = fetch_and_extract(fqdn)
            ResultsWindow(self, fqdn, facts)

    def on_pp_double(self, event):
        sel = self.pp_list.curselection()
        if sel:
            func = self.pp_list.get(sel[0])
            FunctionResultsWindow(self, func)

    def new_search(self):
        new_fqdn = simpledialog.askstring("New Search", "Enter VM FQDN:")
        if new_fqdn:
            facts = fetch_and_extract(new_fqdn)
            ResultsWindow(self, new_fqdn, facts)

    def clear_all(self):
        self.tree.delete(*self.tree.get_children())
        if hasattr(self, 'nodes_list'):
            self.nodes_list.delete(0, 'end')
        self.yaml_list.delete(0, 'end')
        self.pp_list.delete(0, 'end')


class VMFactGUI(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("VM Fact Finder")
        self.geometry("450x150")
        self.resizable(False, False)

        frame = tk.Frame(self)
        frame.pack(pady=20, padx=20)

        tk.Label(frame, text="Enter VM FQDN or Profile Name:").grid(row=0, column=0, sticky='w')
        self.entry = tk.Entry(frame, width=40)
        self.entry.grid(row=1, column=0, pady=5)
        self.entry.focus()

        tk.Button(frame, text="Find VM", command=self.find_vm).grid(row=2, column=0, pady=5)
        tk.Button(frame, text="Find Profile", command=self.find_profile).grid(row=3, column=0, pady=5)

    def find_vm(self):
        fqdn = self.entry.get().strip()
        if not fqdn:
            messagebox.showwarning("Input required", "Please enter a VM FQDN")
            return
        facts = fetch_and_extract(fqdn)
        ResultsWindow(self, fqdn, facts)

    def find_profile(self):
        profile = self.entry.get().strip()
        if not profile:
            messagebox.showwarning("Input required", "Please enter a profile name")
            return
        ProfileResultsWindow(self, profile)


if __name__ == '__main__':
    app = VMFactGUI()
    app.mainloop()
