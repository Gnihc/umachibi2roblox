// Tools > Uma2Roblox
// Lists every character UmaViewer knows, shows which mini (chibi) models are not ported yet,
// and batch-exports the selected ones as Roblox-ready GLBs straight from the live Unity model.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

namespace Uma2Roblox
{
    public class Uma2RobloxWindow : EditorWindow
    {
        const string PrefOut = "Uma2Roblox.OutDir", PrefOpt = "Uma2Roblox.Options", PrefSrv = "Uma2Roblox.Server";

        class Row
        {
            public CharaEntry Chara;
            public List<string> Costumes;
            public int CostumeIdx;
            public bool Selected;
            public string Costume => Costumes.Count > 0 ? Costumes[Mathf.Clamp(CostumeIdx, 0, Costumes.Count - 1)] : "00";
        }

        static readonly PortedRegistry Registry = new PortedRegistry();

        string _outDir;
        ExportOptions _opt = new ExportOptions();
        List<Row> _rows = new List<Row>();
        string _search = "";
        bool _onlyUnported = true, _showOptions;
        Vector2 _scroll;
        string _status = "";
        volatile bool _repaint;

        // batch state
        readonly Queue<Row> _queue = new Queue<Row>();
        Row _current;
        UmaContainerCharacter _prevContainer;
        double _loadStarted;
        int _settle;
        enum BatchState { Idle, NeedLoad, Loading }
        BatchState _state = BatchState.Idle;
        int _batchTotal, _batchDone, _batchFailed;

        [MenuItem("Tools/Uma2Roblox")]
        public static void Open() => GetWindow<Uma2RobloxWindow>("Uma2Roblox");

        void OnEnable()
        {
            _outDir = EditorPrefs.GetString(PrefOut, Path.GetFullPath(Path.Combine(Application.dataPath, "..", "Uma2Roblox_Export")));
            var json = EditorPrefs.GetString(PrefOpt, "");
            if (!string.IsNullOrEmpty(json)) { try { JsonUtility.FromJsonOverwrite(json, _opt); } catch { } }
            Registry.Load(_outDir);
            Registry.Changed += OnRegistryChanged;
            if (EditorPrefs.GetBool(PrefSrv, true)) Registry.StartServer();
            EditorApplication.update += Tick;
        }

        void OnDisable()
        {
            EditorApplication.update -= Tick;
            Registry.Changed -= OnRegistryChanged;
            EditorPrefs.SetString(PrefOpt, JsonUtility.ToJson(_opt));
        }

        void OnRegistryChanged() => _repaint = true;

        static UmaViewerMain Main => UmaViewerMain.Instance;
        static UmaViewerBuilder Builder => UmaViewerBuilder.Instance;
        bool ViewerReady => EditorApplication.isPlaying && Main != null && Builder != null && Main.Characters != null && Main.Characters.Count > 0;

        // ------------------------------------------------------------------ catalog
        void RefreshCatalog()
        {
            var prevSel = new HashSet<int>(_rows.Where(r => r.Selected).Select(r => r.Chara.Id));
            _rows = new List<Row>();
            string bodyPath = UmaDatabaseController.MiniBodyPath;
            foreach (var chara in Main.Characters.OrderBy(c => c.Id))
            {
                string prefix = $"pfb_mbdy{chara.Id}_";
                var costumes = Main.AbChara
                    .Where(a => a.Name.StartsWith(bodyPath) && !a.Name.Contains("clothes") && Path.GetFileName(a.Name).StartsWith(prefix))
                    .Select(a => a.Name.Split('_').Last())
                    .Distinct().OrderBy(s => s).ToList();
                _rows.Add(new Row { Chara = chara, Costumes = costumes, Selected = prevSel.Contains(chara.Id) });
            }
            Registry.Catalog = _rows.Select(r => (r.Chara.Id, r.Chara.GetName(), r.Costumes)).ToList();
            _status = $"{_rows.Count} characters, {_rows.Count(r => r.Costumes.Count > 0)} with a mini model, " +
                      $"{_rows.Count(r => r.Costumes.Count > 0 && !Registry.AnyFor(r.Chara.Id))} not ported.";
        }

        // ------------------------------------------------------------------ GUI
        void OnGUI()
        {
            EditorGUILayout.Space();
            using (new EditorGUILayout.HorizontalScope())
            {
                EditorGUILayout.LabelField("Output folder", GUILayout.Width(90));
                var nd = EditorGUILayout.DelayedTextField(_outDir);
                if (GUILayout.Button("…", GUILayout.Width(28)))
                {
                    var p = EditorUtility.OpenFolderPanel("Uma2Roblox output", _outDir, "");
                    if (!string.IsNullOrEmpty(p)) nd = p;
                }
                if (nd != _outDir) { _outDir = nd; EditorPrefs.SetString(PrefOut, _outDir); Registry.Load(_outDir); }
                if (GUILayout.Button("Open", GUILayout.Width(50))) { Directory.CreateDirectory(_outDir); EditorUtility.RevealInFinder(_outDir + "/"); }
            }

            using (new EditorGUILayout.HorizontalScope())
            {
                bool run = Registry.ServerRunning;
                bool want = EditorGUILayout.ToggleLeft($"Studio sync server (localhost:{PortedRegistry.Port})", run);
                if (want != run) { if (want) Registry.StartServer(); else Registry.StopServer(); EditorPrefs.SetBool(PrefSrv, want); }
            }

            _showOptions = EditorGUILayout.Foldout(_showOptions, "Cartoon / export options", true);
            if (_showOptions) DrawOptions();

            EditorGUILayout.Space();
            if (!EditorApplication.isPlaying)
            {
                EditorGUILayout.HelpBox("Open the Version2 scene, press Play, and wait for UmaViewer to finish loading the game database.", MessageType.Info);
                return;
            }
            if (!ViewerReady) { EditorGUILayout.HelpBox("Waiting for UmaViewer to load the character list…", MessageType.Info); return; }
            if (_rows.Count == 0) RefreshCatalog();

            using (new EditorGUILayout.HorizontalScope())
            {
                _search = EditorGUILayout.TextField(_search, EditorStyles.toolbarSearchField);
                _onlyUnported = GUILayout.Toggle(_onlyUnported, "Only not ported", "Button", GUILayout.Width(110));
                if (GUILayout.Button("Refresh", GUILayout.Width(65))) RefreshCatalog();
            }

            var visible = _rows.Where(r => r.Costumes.Count > 0)
                .Where(r => !_onlyUnported || !Registry.AnyFor(r.Chara.Id))
                .Where(r => string.IsNullOrEmpty(_search) || r.Chara.GetName().IndexOf(_search, StringComparison.OrdinalIgnoreCase) >= 0 || r.Chara.Id.ToString().Contains(_search))
                .ToList();

            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Select all shown")) visible.ForEach(r => r.Selected = true);
                if (GUILayout.Button("Select none")) _rows.ForEach(r => r.Selected = false);
            }

            _scroll = EditorGUILayout.BeginScrollView(_scroll);
            foreach (var r in visible)
            {
                using (new EditorGUILayout.HorizontalScope())
                {
                    r.Selected = EditorGUILayout.Toggle(r.Selected, GUILayout.Width(18));
                    EditorGUILayout.LabelField(r.Chara.Id.ToString(), GUILayout.Width(40));
                    EditorGUILayout.LabelField(r.Chara.GetName(), GUILayout.MinWidth(120));
                    r.CostumeIdx = EditorGUILayout.Popup(r.CostumeIdx, r.Costumes.ToArray(), GUILayout.Width(50));
                    var e = Registry.Get(r.Chara.Id, r.Costume);
                    string st = e == null ? "not ported" : e.imported ? "in Studio" : "exported";
                    var style = new GUIStyle(EditorStyles.miniLabel);
                    style.normal.textColor = e == null ? new Color(0.9f, 0.55f, 0.3f) : e.imported ? new Color(0.4f, 0.8f, 0.4f) : new Color(0.5f, 0.7f, 1f);
                    EditorGUILayout.LabelField(st, style, GUILayout.Width(70));
                    using (new EditorGUI.DisabledScope(_state != BatchState.Idle))
                        if (GUILayout.Button("Load", GUILayout.Width(45))) StartBatch(new[] { r }, exportAfterLoad: false);
                    if (e != null && GUILayout.Button("x", GUILayout.Width(20))) Registry.Forget(r.Chara.Id, r.Costume);
                }
            }
            EditorGUILayout.EndScrollView();

            EditorGUILayout.Space();
            using (new EditorGUI.DisabledScope(_state != BatchState.Idle))
            {
                int n = _rows.Count(r => r.Selected && r.Costumes.Count > 0);
                if (GUILayout.Button($"Batch export selected ({n})", GUILayout.Height(30)) && n > 0)
                    StartBatch(_rows.Where(r => r.Selected && r.Costumes.Count > 0), exportAfterLoad: true);
                if (GUILayout.Button("Export the model currently shown in UmaViewer (keeps your pose/expression edits)"))
                    ExportCurrent(useBindPoseOverride: null);
            }
            if (_state != BatchState.Idle)
            {
                EditorGUILayout.HelpBox($"Working… {_batchDone + _batchFailed}/{_batchTotal}  ({_current?.Chara.GetName()})", MessageType.None);
                if (GUILayout.Button("Cancel")) { _queue.Clear(); _state = BatchState.Idle; _current = null; }
            }
            EditorGUILayout.HelpBox(_status, MessageType.None);
        }

        void DrawOptions()
        {
            EditorGUI.indentLevel++;
            _opt.Shade = (ShadeMode)EditorGUILayout.EnumPopup(new GUIContent("Shading", "Cel: bake 2-tone anime shadow into the texture. Flat: albedo only."), _opt.Shade);
            _opt.FlattenNormals = EditorGUILayout.Toggle(new GUIContent("Disable Roblox shading", "Point all normals up so Roblox lighting is uniform (no smooth Roblox shading)."), _opt.FlattenNormals);
            _opt.Outline = EditorGUILayout.Toggle("Outline (inverted hull)", _opt.Outline);
            using (new EditorGUI.DisabledScope(!_opt.Outline))
            {
                _opt.OutlineWidth = EditorGUILayout.Slider("Outline width", _opt.OutlineWidth, 0.001f, 0.02f);
                _opt.OutlineColor = EditorGUILayout.ColorField("Outline colour", _opt.OutlineColor);
                _opt.OutlineExclude = EditorGUILayout.TextField("Outline exclude", _opt.OutlineExclude);
            }
            using (new EditorGUI.DisabledScope(_opt.Shade != ShadeMode.Cel))
            {
                _opt.LightDirection = EditorGUILayout.Vector3Field("Light dir (y up, z front)", _opt.LightDirection);
                _opt.CelThreshold = EditorGUILayout.Slider("Shadow threshold", _opt.CelThreshold, -0.5f, 0.5f);
                _opt.CelSoftness = EditorGUILayout.Slider("Shadow edge softness", _opt.CelSoftness, 0.001f, 0.2f);
                _opt.ShadowTint = EditorGUILayout.ColorField(new GUIContent("Fallback shadow tint", "Used when the material has no _ToonMap (shad_c)"), _opt.ShadowTint);
                _opt.CelOnFace = EditorGUILayout.Toggle("Cel shadow on face", _opt.CelOnFace);
                _opt.CelExclude = EditorGUILayout.TextField("Cel exclude", _opt.CelExclude);
            }
            _opt.UseBindPose = EditorGUILayout.Toggle(new GUIContent("Export in bind pose", "Off = export the pose currently shown"), _opt.UseBindPose);
            _opt.MaxTextureSize = EditorGUILayout.IntPopup("Max texture size", _opt.MaxTextureSize, new[] { "256", "512", "1024" }, new[] { 256, 512, 1024 });
            _opt.PruneUnusedBones = EditorGUILayout.Toggle("Prune unused bones", _opt.PruneUnusedBones);
            if (GUILayout.Button("Reset options", GUILayout.Width(110))) _opt = new ExportOptions();
            EditorGUI.indentLevel--;
        }

        // ------------------------------------------------------------------ export
        bool _exportAfterLoad;

        void StartBatch(IEnumerable<Row> rows, bool exportAfterLoad)
        {
            _queue.Clear();
            foreach (var r in rows) _queue.Enqueue(r);
            _batchTotal = _queue.Count; _batchDone = _batchFailed = 0;
            _exportAfterLoad = exportAfterLoad;
            _state = BatchState.NeedLoad;
        }

        void Tick()
        {
            if (_repaint) { _repaint = false; Repaint(); }
            if (_state == BatchState.Idle) return;
            if (!ViewerReady) { _state = BatchState.Idle; return; }

            if (_state == BatchState.NeedLoad)
            {
                if (UmaAssetManager.LoadCoroutine != null) return; // UmaViewer is busy loading something
                if (_queue.Count == 0) { FinishBatch(); return; }
                _current = _queue.Dequeue();
                _prevContainer = Builder.CurrentUMAContainer;
                LoadMini(_current.Chara, _current.Costume);
                _loadStarted = EditorApplication.timeSinceStartup;
                _settle = 0;
                _state = BatchState.Loading;
                Repaint();
                return;
            }

            if (_state == BatchState.Loading)
            {
                var c = Builder.CurrentUMAContainer;
                bool loaded = c != null && c != _prevContainer && c.IsMini && c.CharaEntry == _current.Chara && c.Position != null;
                if (!loaded)
                {
                    if (EditorApplication.timeSinceStartup - _loadStarted > 30)
                    {
                        Debug.LogError($"[Uma2Roblox] Timed out loading mini {_current.Chara.Id} {_current.Costume}");
                        _batchFailed++; _state = BatchState.NeedLoad;
                    }
                    return;
                }
                if (++_settle < 10) return; // let a few frames run (materials, facial setup)

                if (_exportAfterLoad)
                {
                    try { ExportContainer(c, _current.Costume); _batchDone++; }
                    catch (Exception e) { Debug.LogException(e); _batchFailed++; }
                }
                else _batchDone++;
                _state = BatchState.NeedLoad;
                Repaint();
            }
        }

        void FinishBatch()
        {
            _state = BatchState.Idle;
            _current = null;
            if (_exportAfterLoad)
            {
                _status = $"Batch finished: {_batchDone} exported, {_batchFailed} failed. Import the .glb files in Studio (File > Import 3D), then click 'Apply Uma Toon' in the plugin.";
                Debug.Log("[Uma2Roblox] " + _status);
            }
            Repaint();
        }

        static void LoadMini(CharaEntry chara, string costume)
        {
            int id = chara.Id;
            var list = new List<UmaDatabaseEntry>();
            string tail = null;
            try
            {
                var data = UmaDatabaseController.ReadCharaData(chara);
                int tailId = Convert.ToInt32(data["tail_model_id"]);
                if (tailId > 0) tail = $"mtail{tailId:0000}_00";
            }
            catch { }
            list.AddRange(Main.AbChara.Where(a => a.Name.StartsWith("3d/chara/mini/") &&
                (a.Name.Contains($"{id}_{costume}") || a.Name.Contains($"mchr{id}_00") || a.Name.Contains("mchr0001_00") ||
                 (tail != null && a.Name.Contains(tail)))));
            if (Main.AbList.TryGetValue($"3d/motion/mini/event/body/chara/chr{id}_00/anm_min_eve_chr{id}_00_idle01_loop", out var motion))
                list.Add(motion);

            Builder.UnloadUma();
            UmaAssetManager.PreLoadAndRun(list, () => Builder.StartCoroutine(Builder.LoadUma(chara, costume, true)));
        }

        void ExportCurrent(bool? useBindPoseOverride)
        {
            var c = Builder ? Builder.CurrentUMAContainer : null;
            if (c == null) { _status = "Nothing is loaded in UmaViewer."; return; }
            if (!c.IsMini) Debug.LogWarning("[Uma2Roblox] The loaded model is not a mini model; exporting anyway.");
            string costume = c.name.StartsWith("Chara_") ? c.name.Substring(c.name.IndexOf('_', 6) + 1) : "00";
            try
            {
                var keepPose = _opt.UseBindPose;
                if (useBindPoseOverride.HasValue) _opt.UseBindPose = useBindPoseOverride.Value;
                ExportContainer(c, costume);
                _opt.UseBindPose = keepPose;
            }
            catch (Exception e) { Debug.LogException(e); _status = "Export failed: " + e.Message; }
        }

        void ExportContainer(UmaContainerCharacter c, string costume)
        {
            int id = c.CharaEntry != null ? c.CharaEntry.Id : 0;
            string name = c.CharaEntry != null ? c.CharaEntry.GetName() : c.name;
            string baseName = $"Uma_{id}_{costume}_{RobloxGlbExporter.Sanitize(name)}";
            var res = RobloxGlbExporter.Export(c, _outDir, baseName, _opt);
            Registry.MarkExported(id, name, costume, Path.GetFileName(res.GlbPath));
            _status = $"Exported {baseName}.glb — {res.Meshes} meshes, {res.Triangles} tris, {res.Bones} bones.";
            foreach (var w in res.Warnings) Debug.LogWarning("[Uma2Roblox] " + baseName + ": " + w);
            Debug.Log("[Uma2Roblox] " + _status + "\n" + res.GlbPath);
        }
    }
}
