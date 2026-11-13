// Uma2Roblox - exports a loaded UmaViewer character (mini/chibi) as a Roblox-ready skinned GLB.
//
// It reads the live Unity objects that UmaViewer builds (SkinnedMeshRenderers, real bones,
// bindposes, UVs, the toon materials' _MainTex / _ToonMap) instead of going through PMX.
//
// "Cartoon shading" for Roblox (which has no custom shaders) is done by:
//   1. Baking a 2-tone cel shadow into the albedo texture (Uma's own _ToonMap / shad_c is used
//      as the shadow colour when present), or keeping the albedo flat (ShadeMode.Flat).
//   2. Rewriting every vertex normal to point straight up. Roblox lighting then becomes uniform
//      across the whole mesh, so it no longer adds its own smooth "Roblox" shading gradient.
//   3. Generating an inverted-hull outline mesh (works in Roblox because of back-face culling).
//   The Studio plugin then turns off CastShadow, so the model also casts no shadows.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;

namespace Uma2Roblox
{
    public enum ShadeMode { Cel, Flat }

    [Serializable]
    public class ExportOptions
    {
        public ShadeMode Shade = ShadeMode.Cel;
        public bool FlattenNormals = true;
        public bool Outline = true;
        [Tooltip("Outline thickness as a fraction of model height")]
        public float OutlineWidth = 0.006f;
        public Color OutlineColor = new Color(0.16f, 0.11f, 0.13f, 1f);
        [Tooltip("Reset bones to the mesh bind pose (T/A pose) before export")]
        public bool UseBindPose = true;
        public bool CelOnFace = false;
        public float CelThreshold = 0.0f;
        public float CelSoftness = 0.03f;
        [Tooltip("Shadow colour multiplier used when a material has no _ToonMap (shad_c)")]
        public Color ShadowTint = new Color(0.80f, 0.74f, 0.88f, 1f);
        [Tooltip("Light direction for the baked cel shadow. y = up, z = toward the character's front")]
        public Vector3 LightDirection = new Vector3(0f, 0.85f, 0.55f);
        public int MaxTextureSize = 1024;
        public bool PruneUnusedBones = true;
        public string OutlineExclude = "eye,mouth,mayu,cheek,tear,alpha";
        public string CelExclude = "eye,mouth,mayu,cheek,tear";
    }

    public class ExportResult
    {
        public string GlbPath;
        public string MetaPath;
        public int Triangles;
        public int Bones;
        public int Meshes;
        public List<string> Warnings = new List<string>();
    }

    public static class RobloxGlbExporter
    {
        // ---------------------------------------------------------------- data
        class Prim
        {
            public string Name;
            public string Kind;            // lower-case renderer+material name, for classification
            public Material Mat;
            public List<Vector3> Pos = new List<Vector3>();   // container (root) space, Unity coords
            public List<Vector3> Nrm = new List<Vector3>();
            public List<Vector2> Uv = new List<Vector2>();    // Unity convention (v up), ST applied
            public List<int> J = new List<int>();             // 4 per vertex
            public List<float> W = new List<float>();         // 4 per vertex
            public List<int> Idx = new List<int>();           // Unity winding
            public int MaterialIndex;
            public bool IsOutline;
        }

        struct TexOut { public byte[] Png; public string Alpha; }

        // ---------------------------------------------------------------- entry
        public static ExportResult Export(UmaContainerCharacter c, string outDir, string baseName, ExportOptions o)
        {
            var res = new ExportResult();
            Directory.CreateDirectory(outDir);
            Transform root = c.transform;

            var saved = SaveTransforms(root);
            var animators = root.GetComponentsInChildren<Animator>(true).Where(a => a.enabled).ToList();
            try { c.SetDynamicBoneEnable(false); } catch { }
            try { c.EnablePhysics = false; } catch { }
            foreach (var a in animators) a.enabled = false;

            try
            {
                if (o.UseBindPose) ApplyBindPose(root, res);

                var renderers = root.GetComponentsInChildren<Renderer>(false)
                    .Where(r => r.enabled && r.gameObject.activeInHierarchy && (r is SkinnedMeshRenderer || r is MeshRenderer))
                    .ToList();
                if (renderers.Count == 0) throw new Exception("No renderers found on the loaded character.");

                // -------- joints
                var jointSet = new HashSet<Transform>();
                void AddChain(Transform t) { while (t != null && t != root && jointSet.Add(t)) t = t.parent; }
                foreach (var r in renderers)
                {
                    if (r is SkinnedMeshRenderer smr)
                    {
                        foreach (var b in smr.bones) if (b) AddChain(b);
                        if (smr.rootBone) AddChain(smr.rootBone);
                    }
                    else AddChain(r.transform);
                }
                var joints = root.GetComponentsInChildren<Transform>(true).Where(jointSet.Contains).ToList(); // DFS order: parents first
                var jointIndex = new Dictionary<Transform, int>();
                for (int i = 0; i < joints.Count; i++) jointIndex[joints[i]] = i;

                int JointOf(Transform t)
                {
                    while (t != null && t != root)
                    {
                        if (jointIndex.TryGetValue(t, out int ji)) return ji;
                        t = t.parent;
                    }
                    return 0;
                }

                // -------- primitives
                var prims = new List<Prim>();
                Matrix4x4 rootInv = root.worldToLocalMatrix;
                foreach (var r in renderers)
                {
                    Mesh src; Matrix4x4 toRoot; Vector3[] verts, norms; BoneWeight[] bw = null; Transform[] bones = null;
                    bool isSkinned = r is SkinnedMeshRenderer;
                    if (r is SkinnedMeshRenderer smr)
                    {
                        src = smr.sharedMesh;
                        if (!src) continue;
                        Mesh readable = EnsureReadable(src, out bool isCopy);
                        var baked = new Mesh();
                        if (isCopy) smr.sharedMesh = readable;
                        try { smr.BakeMesh(baked, true); }
                        finally { if (isCopy) smr.sharedMesh = src; }
                        verts = baked.vertices; norms = baked.normals;
                        bw = readable.boneWeights; bones = smr.bones;
                        toRoot = rootInv * smr.transform.localToWorldMatrix;
                        src = readable;
                    }
                    else
                    {
                        var mf = r.GetComponent<MeshFilter>();
                        if (!mf || !mf.sharedMesh) continue;
                        src = EnsureReadable(mf.sharedMesh, out _);
                        verts = src.vertices; norms = src.normals;
                        toRoot = rootInv * r.transform.localToWorldMatrix;
                    }
                    if (norms == null || norms.Length != verts.Length) { src.RecalculateNormals(); norms = src.normals; }
                    var uvs = src.uv;
                    if (uvs == null || uvs.Length != verts.Length) uvs = new Vector2[verts.Length];
                    int rigidJoint = JointOf(r.transform);

                    var mats = r.sharedMaterials;
                    for (int s = 0; s < src.subMeshCount; s++)
                    {
                        if (src.GetTopology(s) != MeshTopology.Triangles) continue;
                        var mat = mats.Length == 0 ? null : mats[Mathf.Min(s, mats.Length - 1)];
                        var tris = src.GetTriangles(s);
                        if (tris.Length == 0) continue;
                        string matName = mat ? mat.name.Replace(" (Instance)", "") : "nomat";
                        var p = new Prim
                        {
                            Name = Sanitize($"{r.name}_{matName}"),
                            Kind = (r.name + " " + matName).ToLowerInvariant(),
                            Mat = mat
                        };
                        Vector2 st = mat && mat.HasProperty("_MainTex") ? mat.mainTextureScale : Vector2.one;
                        Vector2 off = mat && mat.HasProperty("_MainTex") ? mat.mainTextureOffset : Vector2.zero;
                        var remap = new Dictionary<int, int>();
                        foreach (int vi in tris)
                        {
                            if (!remap.TryGetValue(vi, out int ni))
                            {
                                ni = p.Pos.Count; remap[vi] = ni;
                                p.Pos.Add(toRoot.MultiplyPoint3x4(verts[vi]));
                                p.Nrm.Add(toRoot.MultiplyVector(norms[vi]).normalized);
                                p.Uv.Add(new Vector2(uvs[vi].x * st.x + off.x, uvs[vi].y * st.y + off.y));
                                if (isSkinned && bw != null && vi < bw.Length)
                                {
                                    var w = bw[vi];
                                    AddInfluence(p, bones, w.boneIndex0, w.weight0, JointOf, rigidJoint);
                                    AddInfluence(p, bones, w.boneIndex1, w.weight1, JointOf, rigidJoint);
                                    AddInfluence(p, bones, w.boneIndex2, w.weight2, JointOf, rigidJoint);
                                    AddInfluence(p, bones, w.boneIndex3, w.weight3, JointOf, rigidJoint);
                                    NormalizeLast4(p);
                                }
                                else
                                {
                                    p.J.Add(rigidJoint); p.J.Add(0); p.J.Add(0); p.J.Add(0);
                                    p.W.Add(1); p.W.Add(0); p.W.Add(0); p.W.Add(0);
                                }
                            }
                            p.Idx.Add(ni);
                        }
                        prims.Add(p);
                    }
                }
                if (prims.Count == 0) throw new Exception("Nothing to export (no readable meshes).");

                // -------- bounds / facing
                var allPos = prims.SelectMany(p => p.Pos).ToList();
                float minY = allPos.Min(v => v.y), maxY = allPos.Max(v => v.y);
                float height = Mathf.Max(0.001f, maxY - minY);
                float forwardZ = DetectForward(prims, joints);
                Vector3 L = new Vector3(o.LightDirection.x, o.LightDirection.y, o.LightDirection.z * forwardZ).normalized;

                // -------- materials / textures
                var images = new List<TexOut>();
                var materialsJson = new JArray();
                var flatCache = new Dictionary<string, int>();
                string[] celEx = Split(o.CelExclude), outEx = Split(o.OutlineExclude);
                var alphaModes = new Dictionary<Prim, string>();
                foreach (var p in prims)
                {
                    bool facePart = p.Kind.Contains("face");
                    bool doCel = o.Shade == ShadeMode.Cel && !celEx.Any(p.Kind.Contains) && (o.CelOnFace || !facePart);
                    Texture2D main = GetTex(p.Mat, "_MainTex");
                    TexOut t;
                    string cacheKey = null;
                    if (!doCel && main) cacheKey = main.GetInstanceID() + "|" + QueueAlpha(p);
                    if (cacheKey != null && flatCache.TryGetValue(cacheKey, out int cachedImg))
                    {
                        t = images[cachedImg];
                        p.MaterialIndex = AddMaterial(materialsJson, p.Name, cachedImg, t.Alpha);
                        alphaModes[p] = t.Alpha;
                        continue;
                    }
                    t = BuildTexture(p, main, doCel, L, o, res);
                    images.Add(t);
                    if (cacheKey != null) flatCache[cacheKey] = images.Count - 1;
                    p.MaterialIndex = AddMaterial(materialsJson, p.Name, images.Count - 1, t.Alpha);
                    alphaModes[p] = t.Alpha;
                }

                // -------- outline hull
                if (o.Outline)
                {
                    var eligible = prims.Where(p => alphaModes[p] == "OPAQUE" && !outEx.Any(p.Kind.Contains)).ToList();
                    if (eligible.Count > 0)
                    {
                        images.Add(new TexOut { Png = SolidPng(o.OutlineColor), Alpha = "OPAQUE" });
                        int outlineMat = AddMaterial(materialsJson, "Outline", images.Count - 1, "OPAQUE");
                        var outline = BuildOutline(eligible, height * o.OutlineWidth, height);
                        outline.MaterialIndex = outlineMat;
                        prims.Add(outline);
                    }
                }

                if (o.FlattenNormals)
                    foreach (var p in prims) for (int i = 0; i < p.Nrm.Count; i++) p.Nrm[i] = Vector3.up;

                // -------- prune joints
                var used = new bool[joints.Count];
                foreach (var p in prims)
                    for (int i = 0; i < p.J.Count; i++) if (p.W[i] > 0f) used[p.J[i]] = true;
                foreach (var r in renderers) if (r is MeshRenderer) used[JointOf(r.transform)] = true;
                var keep = new bool[joints.Count];
                for (int i = 0; i < joints.Count; i++)
                {
                    if (!o.PruneUnusedBones || used[i])
                        for (var t = joints[i]; t != null && t != root; t = t.parent)
                            if (jointIndex.TryGetValue(t, out int ai)) keep[ai] = true;
                }
                var newIndex = new int[joints.Count];
                var finalJoints = new List<Transform>();
                for (int i = 0; i < joints.Count; i++) { newIndex[i] = keep[i] ? finalJoints.Count : -1; if (keep[i]) finalJoints.Add(joints[i]); }
                foreach (var p in prims)
                    for (int i = 0; i < p.J.Count; i++)
                    {
                        int ni = newIndex[p.J[i]];
                        if (ni < 0) { ni = 0; p.W[i] = 0; }
                        p.J[i] = ni;
                    }

                // -------- write
                string glbPath = Path.Combine(outDir, baseName + ".glb");
                WriteGlb(glbPath, baseName, root, finalJoints, prims, images, materialsJson, forwardZ);
                res.GlbPath = glbPath;
                res.Bones = finalJoints.Count;
                res.Meshes = prims.Count;
                res.Triangles = prims.Sum(p => p.Idx.Count / 3);
                foreach (var p in prims)
                    if (p.Idx.Count / 3 > 20000)
                        res.Warnings.Add($"{p.Name} has {p.Idx.Count / 3} triangles (> Roblox's 20k per MeshPart limit).");
                if (finalJoints.Count > 250) res.Warnings.Add($"{finalJoints.Count} bones; Roblox may be slow with this many.");

                // sidecar metadata
                var meta = new JObject
                {
                    ["tool"] = "Uma2Roblox",
                    ["charaId"] = c.CharaEntry != null ? c.CharaEntry.Id : 0,
                    ["name"] = c.CharaEntry != null ? c.CharaEntry.GetName() : c.name,
                    ["glb"] = Path.GetFileName(glbPath),
                    ["heightUnity"] = height,
                    ["bones"] = res.Bones,
                    ["meshes"] = res.Meshes,
                    ["triangles"] = res.Triangles,
                    ["shade"] = o.Shade.ToString(),
                    ["exportedAt"] = DateTime.UtcNow.ToString("o"),
                    ["warnings"] = new JArray(res.Warnings)
                };
                res.MetaPath = Path.Combine(outDir, baseName + ".json");
                File.WriteAllText(res.MetaPath, meta.ToString(Formatting.Indented));
            }
            finally
            {
                RestoreTransforms(saved);
                foreach (var a in animators) if (a) a.enabled = true;
                try { c.EnablePhysics = true; c.SetDynamicBoneEnable(UmaViewerUI.Instance.ModelSettings.DynamicBoneEnable); } catch { }
            }
            return res;
        }

        // ---------------------------------------------------------------- pose
        static List<(Transform t, Vector3 p, Quaternion r, Vector3 s)> SaveTransforms(Transform root) =>
            root.GetComponentsInChildren<Transform>(true).Select(t => (t, t.localPosition, t.localRotation, t.localScale)).ToList();

        static void RestoreTransforms(List<(Transform t, Vector3 p, Quaternion r, Vector3 s)> saved)
        {
            foreach (var e in saved)
                if (e.t) { e.t.localPosition = e.p; e.t.localRotation = e.r; e.t.localScale = e.s; }
        }

        static void ApplyBindPose(Transform root, ExportResult res)
        {
            var targets = new Dictionary<Transform, Matrix4x4>();
            var smrs = root.GetComponentsInChildren<SkinnedMeshRenderer>(false).OrderByDescending(s => s.bones.Length);
            foreach (var smr in smrs)
            {
                var mesh = smr.sharedMesh;
                if (!mesh) continue;
                var bp = mesh.bindposes;
                var bones = smr.bones;
                var m = smr.transform.localToWorldMatrix;
                for (int i = 0; i < Mathf.Min(bp.Length, bones.Length); i++)
                {
                    var b = bones[i];
                    if (!b || targets.ContainsKey(b)) continue;
                    targets[b] = m * bp[i].inverse;
                }
            }
            if (targets.Count == 0) { res.Warnings.Add("No bindposes found; exported current pose."); return; }
            foreach (var kv in targets.OrderBy(k => Depth(k.Key)))
            {
                var t = kv.Key; var mtx = kv.Value;
                t.position = mtx.GetColumn(3);
                t.rotation = mtx.rotation;
                Vector3 ls = mtx.lossyScale;
                Vector3 ps = t.parent ? t.parent.lossyScale : Vector3.one;
                t.localScale = new Vector3(SafeDiv(ls.x, ps.x), SafeDiv(ls.y, ps.y), SafeDiv(ls.z, ps.z));
            }
        }

        static float SafeDiv(float a, float b) => Mathf.Abs(b) < 1e-6f ? a : a / b;
        static int Depth(Transform t) { int d = 0; while (t.parent) { d++; t = t.parent; } return d; }

        // ---------------------------------------------------------------- mesh helpers
        static void AddInfluence(Prim p, Transform[] bones, int bi, float w, Func<Transform, int> jointOf, int fallback)
        {
            int j = (bones != null && bi >= 0 && bi < bones.Length && bones[bi]) ? jointOf(bones[bi]) : fallback;
            p.J.Add(j); p.W.Add(w);
        }

        static void NormalizeLast4(Prim p)
        {
            int b = p.W.Count - 4;
            // merge duplicate joints, then normalise
            for (int i = 0; i < 4; i++)
                for (int k = i + 1; k < 4; k++)
                    if (p.W[b + k] > 0 && p.J[b + k] == p.J[b + i]) { p.W[b + i] += p.W[b + k]; p.W[b + k] = 0; }
            float sum = p.W[b] + p.W[b + 1] + p.W[b + 2] + p.W[b + 3];
            if (sum <= 1e-6f) { p.W[b] = 1; p.W[b + 1] = p.W[b + 2] = p.W[b + 3] = 0; return; }
            for (int i = 0; i < 4; i++) { p.W[b + i] /= sum; if (p.W[b + i] == 0) p.J[b + i] = 0; }
        }

        static Mesh EnsureReadable(Mesh m, out bool isCopy)
        {
            isCopy = false;
            if (m.isReadable) return m;
            isCopy = true;
            var copy = new Mesh { indexFormat = m.indexFormat, name = m.name + "_readable" };
            copy.SetVertexBufferParams(m.vertexCount, m.GetVertexAttributes());
            for (int s = 0; s < m.vertexBufferCount; s++)
            {
                using (var vb = m.GetVertexBuffer(s))
                {
                    var data = new byte[vb.stride * vb.count];
                    vb.GetData(data);
                    copy.SetVertexBufferData(data, 0, 0, data.Length, s);
                }
            }
            using (var ib = m.GetIndexBuffer())
            {
                var idata = new byte[ib.stride * ib.count];
                ib.GetData(idata);
                copy.SetIndexBufferParams(ib.count, m.indexFormat);
                copy.SetIndexBufferData(idata, 0, 0, idata.Length);
            }
            copy.subMeshCount = m.subMeshCount;
            for (int i = 0; i < m.subMeshCount; i++)
            {
                var d = m.GetSubMesh(i);
                copy.SetSubMesh(i, new SubMeshDescriptor(d.indexStart, d.indexCount, d.topology) { baseVertex = d.baseVertex },
                    MeshUpdateFlags.DontRecalculateBounds);
            }
            copy.bindposes = m.bindposes;
            copy.RecalculateBounds();
            return copy;
        }

        static float DetectForward(List<Prim> prims, List<Transform> joints)
        {
            // The eyes sit in front of the centre of the head region, so compare their z with
            // the average z of the upper part of the model.
            var eyes = prims.Where(p => p.Kind.Contains("eye")).SelectMany(p => p.Pos).ToList();
            if (eyes.Count == 0) eyes = prims.Where(p => p.Kind.Contains("face")).SelectMany(p => p.Pos).ToList();
            if (eyes.Count == 0) return 1f;
            float ez = eyes.Average(v => v.z);
            var all = prims.SelectMany(p => p.Pos).ToList();
            float maxY = all.Max(v => v.y), minY = all.Min(v => v.y);
            var headVerts = all.Where(v => v.y > maxY - (maxY - minY) * 0.45f).ToList();
            float hz = headVerts.Count > 0 ? headVerts.Average(v => v.z) : 0f;
            return ez >= hz ? 1f : -1f;
        }

        static Prim BuildOutline(List<Prim> src, float width, float height)
        {
            // smooth normals across UV seams / separate meshes by welding on position
            float q = Mathf.Max(1e-5f, height * 1e-4f);
            var acc = new Dictionary<(int, int, int), Vector3>();
            (int, int, int) Key(Vector3 v) => (Mathf.RoundToInt(v.x / q), Mathf.RoundToInt(v.y / q), Mathf.RoundToInt(v.z / q));
            foreach (var p in src)
                for (int i = 0; i < p.Pos.Count; i++)
                {
                    var k = Key(p.Pos[i]);
                    acc[k] = (acc.TryGetValue(k, out var n) ? n : Vector3.zero) + p.Nrm[i];
                }
            var o = new Prim { Name = "Outline", Kind = "outline", IsOutline = true };
            foreach (var p in src)
            {
                int baseV = o.Pos.Count;
                for (int i = 0; i < p.Pos.Count; i++)
                {
                    var n = acc[Key(p.Pos[i])].normalized;
                    if (n == Vector3.zero) n = p.Nrm[i];
                    o.Pos.Add(p.Pos[i] + n * width);
                    o.Nrm.Add(-n);
                    o.Uv.Add(new Vector2(0.5f, 0.5f));
                }
                o.J.AddRange(p.J); o.W.AddRange(p.W);
                for (int t = 0; t < p.Idx.Count; t += 3)
                {   // reversed winding -> only the back faces of the hull render
                    o.Idx.Add(baseV + p.Idx[t]); o.Idx.Add(baseV + p.Idx[t + 2]); o.Idx.Add(baseV + p.Idx[t + 1]);
                }
            }
            return o;
        }

        // ---------------------------------------------------------------- textures
        static Texture2D GetTex(Material m, string prop) =>
            m && m.HasProperty(prop) ? m.GetTexture(prop) as Texture2D : null;

        static string QueueAlpha(Prim p)
        {
            if (!p.Mat) return "OPAQUE";
            string sh = p.Mat.shader ? p.Mat.shader.name.ToLowerInvariant() : "";
            if (p.Mat.renderQueue >= 2900 || sh.Contains("alpha") || sh.Contains("transparent") || p.Kind.Contains("cheek") || p.Kind.Contains("tear"))
                return "BLEND";
            if (p.Mat.renderQueue >= 2450) return "MASK";
            return "OPAQUE";
        }

        static Color32[] ReadPixels(Texture tex, int w, int h)
        {
            var rt = RenderTexture.GetTemporary(w, h, 0, RenderTextureFormat.Default, RenderTextureReadWrite.Linear);
            Graphics.Blit(tex, rt);
            var prev = RenderTexture.active;
            RenderTexture.active = rt;
            var t2 = new Texture2D(w, h, TextureFormat.RGBA32, false);
            t2.ReadPixels(new Rect(0, 0, w, h), 0, 0);
            t2.Apply();
            RenderTexture.active = prev;
            RenderTexture.ReleaseTemporary(rt);
            var px = t2.GetPixels32();
            UnityEngine.Object.DestroyImmediate(t2);
            return px;
        }

        static TexOut BuildTexture(Prim p, Texture2D main, bool doCel, Vector3 L, ExportOptions o, ExportResult res)
        {
            string alpha = QueueAlpha(p);
            if (!main)
            {
                Color col = p.Mat && p.Mat.HasProperty("_Color") ? p.Mat.color : Color.white;
                return new TexOut { Png = SolidPng(col), Alpha = alpha == "BLEND" ? "BLEND" : "OPAQUE" };
            }
            float scale = Mathf.Min(1f, (float)o.MaxTextureSize / Mathf.Max(main.width, main.height));
            int w = Mathf.Max(4, Mathf.RoundToInt(main.width * scale));
            int h = Mathf.Max(4, Mathf.RoundToInt(main.height * scale));
            var px = ReadPixels(main, w, h);

            bool facePart = p.Kind.Contains("eye") || p.Kind.Contains("mouth") || p.Kind.Contains("mayu") || p.Kind.Contains("cheek");
            if (alpha == "OPAQUE" && facePart && px.Any(c => c.a < 250)) alpha = "BLEND";

            if (doCel)
            {
                Texture2D toon = GetTex(p.Mat, "_ToonMap");
                Color32[] shadow = toon ? ReadPixels(toon, w, h) : null;
                float[] lit = RasterLitMask(p, w, h, L, o.CelThreshold, o.CelSoftness);
                Color tint = o.ShadowTint;
                for (int i = 0; i < px.Length; i++)
                {
                    float k = lit[i];
                    if (k >= 0.999f) continue;
                    Color32 a = px[i];
                    Color32 s = shadow != null ? shadow[i]
                        : new Color32((byte)(a.r * tint.r), (byte)(a.g * tint.g), (byte)(a.b * tint.b), a.a);
                    px[i] = new Color32(
                        (byte)Mathf.Lerp(s.r, a.r, k), (byte)Mathf.Lerp(s.g, a.g, k), (byte)Mathf.Lerp(s.b, a.b, k), a.a);
                }
            }
            if (alpha == "OPAQUE") for (int i = 0; i < px.Length; i++) px[i].a = 255;

            var outTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
            outTex.SetPixels32(px);
            outTex.Apply();
            var png = outTex.EncodeToPNG();
            UnityEngine.Object.DestroyImmediate(outTex);
            return new TexOut { Png = png, Alpha = alpha };
        }

        /// Rasterises the primitive's triangles in UV space and returns, per texel, how lit it is (0..1)
        /// for a fixed directional light. Texels not covered by the mesh are treated as lit.
        static float[] RasterLitMask(Prim p, int w, int h, Vector3 L, float th, float soft)
        {
            var mask = new float[w * h];
            for (int i = 0; i < mask.Length; i++) mask[i] = -1f;
            for (int t = 0; t < p.Idx.Count; t += 3)
            {
                int a = p.Idx[t], b = p.Idx[t + 1], c = p.Idx[t + 2];
                Vector2 A = Wrap(p.Uv[a]), B = Wrap(p.Uv[b]), C = Wrap(p.Uv[c]);
                // skip triangles whose UVs straddle a wrap boundary
                if (Mathf.Abs(A.x - B.x) > 0.5f || Mathf.Abs(A.x - C.x) > 0.5f || Mathf.Abs(A.y - B.y) > 0.5f || Mathf.Abs(A.y - C.y) > 0.5f) continue;
                Vector2 pa = new Vector2(A.x * w - 0.5f, A.y * h - 0.5f), pb = new Vector2(B.x * w - 0.5f, B.y * h - 0.5f), pc = new Vector2(C.x * w - 0.5f, C.y * h - 0.5f);
                float area = (pb.x - pa.x) * (pc.y - pa.y) - (pc.x - pa.x) * (pb.y - pa.y);
                if (Mathf.Abs(area) < 1e-8f) continue;
                int x0 = Mathf.Max(0, Mathf.FloorToInt(Mathf.Min(pa.x, Mathf.Min(pb.x, pc.x))) - 1);
                int x1 = Mathf.Min(w - 1, Mathf.CeilToInt(Mathf.Max(pa.x, Mathf.Max(pb.x, pc.x))) + 1);
                int y0 = Mathf.Max(0, Mathf.FloorToInt(Mathf.Min(pa.y, Mathf.Min(pb.y, pc.y))) - 1);
                int y1 = Mathf.Min(h - 1, Mathf.CeilToInt(Mathf.Max(pa.y, Mathf.Max(pb.y, pc.y))) + 1);
                Vector3 na = p.Nrm[a], nb = p.Nrm[b], nc = p.Nrm[c];
                float eps = -0.75f / Mathf.Sqrt(Mathf.Abs(area)); // ~1 texel conservative
                for (int y = y0; y <= y1; y++)
                    for (int x = x0; x <= x1; x++)
                    {
                        float w0 = ((pb.x - x) * (pc.y - y) - (pc.x - x) * (pb.y - y)) / area;
                        float w1 = ((pc.x - x) * (pa.y - y) - (pa.x - x) * (pc.y - y)) / area;
                        float w2 = 1f - w0 - w1;
                        if (w0 < eps || w1 < eps || w2 < eps) continue;
                        Vector3 n = (na * w0 + nb * w1 + nc * w2).normalized;
                        float d = Vector3.Dot(n, L);
                        float lit = Mathf.Clamp01((d - (th - soft)) / Mathf.Max(1e-4f, 2f * soft));
                        lit = lit * lit * (3f - 2f * lit);
                        int idx = y * w + x;
                        mask[idx] = Mathf.Max(mask[idx], lit); // mirrored UVs: lit wins
                    }
            }
            // dilate covered texels into the gutter so bilinear filtering doesn't bleed at seams
            for (int pass = 0; pass < 3; pass++)
            {
                var copy = (float[])mask.Clone();
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int i = y * w + x;
                        if (copy[i] >= 0) continue;
                        float best = -1f;
                        if (x > 0) best = Mathf.Max(best, copy[i - 1]);
                        if (x < w - 1) best = Mathf.Max(best, copy[i + 1]);
                        if (y > 0) best = Mathf.Max(best, copy[i - w]);
                        if (y < h - 1) best = Mathf.Max(best, copy[i + w]);
                        if (best >= 0) mask[i] = best;
                    }
            }
            for (int i = 0; i < mask.Length; i++) if (mask[i] < 0) mask[i] = 1f;
            return mask;
        }

        static Vector2 Wrap(Vector2 uv) => new Vector2(uv.x - Mathf.Floor(uv.x), uv.y - Mathf.Floor(uv.y));

        static byte[] SolidPng(Color c)
        {
            var t = new Texture2D(4, 4, TextureFormat.RGBA32, false);
            var px = Enumerable.Repeat((Color32)new Color(c.r, c.g, c.b, 1f), 16).ToArray();
            t.SetPixels32(px); t.Apply();
            var png = t.EncodeToPNG();
            UnityEngine.Object.DestroyImmediate(t);
            return png;
        }

        static int AddMaterial(JArray mats, string name, int image, string alpha)
        {
            var m = new JObject
            {
                ["name"] = name,
                ["pbrMetallicRoughness"] = new JObject
                {
                    ["baseColorTexture"] = new JObject { ["index"] = image },
                    ["metallicFactor"] = 0.0,
                    ["roughnessFactor"] = 1.0
                },
                ["alphaMode"] = alpha,
                ["doubleSided"] = false,
                ["extensions"] = new JObject { ["KHR_materials_unlit"] = new JObject() }
            };
            if (alpha == "MASK") m["alphaCutoff"] = 0.5;
            mats.Add(m);
            return mats.Count - 1;
        }

        // ---------------------------------------------------------------- glTF writer
        class Bin
        {
            public readonly MemoryStream Data = new MemoryStream();
            public readonly JArray Views = new JArray();
            public readonly JArray Accessors = new JArray();

            public int View(byte[] bytes, int? target)
            {
                while (Data.Length % 4 != 0) Data.WriteByte(0);
                var v = new JObject { ["buffer"] = 0, ["byteOffset"] = Data.Length, ["byteLength"] = bytes.Length };
                if (target.HasValue) v["target"] = target.Value;
                Data.Write(bytes, 0, bytes.Length);
                Views.Add(v);
                return Views.Count - 1;
            }

            public int Accessor(byte[] bytes, int componentType, int count, string type, int? target, JArray min = null, JArray max = null)
            {
                var a = new JObject { ["bufferView"] = View(bytes, target), ["componentType"] = componentType, ["count"] = count, ["type"] = type };
                if (min != null) { a["min"] = min; a["max"] = max; }
                Accessors.Add(a);
                return Accessors.Count - 1;
            }
        }

        const int FLOAT = 5126, USHORT = 5123, UINT = 5125, ARRAY_BUFFER = 34962, ELEMENT_ARRAY_BUFFER = 34963;

        // Unity (left-handed) -> glTF (right-handed) needs one mirror. Mirroring X keeps the facing
        // direction; mirroring Z additionally turns the model 180 degrees. We pick whichever leaves the
        // character facing +Z (the glTF front), so no extra root rotation is needed.
        static bool _mirrorZ;
        static Vector3 CvP(Vector3 v) => _mirrorZ ? new Vector3(v.x, v.y, -v.z) : new Vector3(-v.x, v.y, v.z);
        static Quaternion CvQ(Quaternion q) => _mirrorZ ? new Quaternion(-q.x, -q.y, q.z, q.w) : new Quaternion(q.x, -q.y, -q.z, q.w);
        static Matrix4x4 CvM(Matrix4x4 m)
        {
            var s = Matrix4x4.Scale(_mirrorZ ? new Vector3(1, 1, -1) : new Vector3(-1, 1, 1));
            return s * m * s;
        }

        static void WriteGlb(string path, string name, Transform root, List<Transform> joints, List<Prim> prims,
            List<TexOut> images, JArray materials, float forwardZ)
        {
            var bin = new Bin();
            var nodes = new JArray();
            var meshes = new JArray();
            var rootChildren = new JArray();   // joints directly under the armature root
            var sceneNodes = new JArray(0);     // armature root + skinned mesh nodes (kept at scene root)
            _mirrorZ = forwardZ < 0;

            // node 0: armature root
            var rootNode = new JObject { ["name"] = name };
            nodes.Add(rootNode);

            // joints
            var jIndex = new Dictionary<Transform, int>();
            var usedNames = new HashSet<string>();
            int jointBase = nodes.Count;
            for (int i = 0; i < joints.Count; i++)
            {
                var t = joints[i];
                string jn = Sanitize(t.name);
                string u = jn; int k = 2;
                while (!usedNames.Add(u)) u = jn + "_" + k++;
                Vector3 lp; Quaternion lr; Vector3 ls;
                if (t.parent == root || !jIndex.ContainsKey(t.parent))
                {
                    // relative to the container root
                    var m = root.worldToLocalMatrix * t.localToWorldMatrix;
                    lp = m.GetColumn(3); lr = m.rotation; ls = m.lossyScale;
                }
                else { lp = t.localPosition; lr = t.localRotation; ls = t.localScale; }
                lp = CvP(lp); lr = CvQ(lr);
                var node = new JObject
                {
                    ["name"] = u,
                    ["translation"] = new JArray(lp.x, lp.y, lp.z),
                    ["rotation"] = new JArray(lr.x, lr.y, lr.z, lr.w)
                };
                if ((ls - Vector3.one).sqrMagnitude > 1e-8f) node["scale"] = new JArray(ls.x, ls.y, ls.z);
                nodes.Add(node);
                jIndex[t] = jointBase + i;
            }
            for (int i = 0; i < joints.Count; i++)
            {
                var t = joints[i];
                if (t.parent != root && jIndex.TryGetValue(t.parent, out int pi))
                {
                    var parent = (JObject)nodes[pi];
                    if (parent["children"] == null) parent["children"] = new JArray();
                    ((JArray)parent["children"]).Add(jointBase + i);
                }
                else rootChildren.Add(jointBase + i);
            }

            // inverse bind matrices (current joint world, in root space)
            var ibm = new List<float>();
            foreach (var t in joints)
            {
                var m = CvM(root.worldToLocalMatrix * t.localToWorldMatrix).inverse;
                for (int col = 0; col < 4; col++) for (int row = 0; row < 4; row++) ibm.Add(m[row, col]);
            }
            int ibmAcc = bin.Accessor(Floats(ibm), FLOAT, joints.Count, "MAT4", null);
            var skin = new JObject
            {
                ["name"] = name + "_Skin",
                ["joints"] = new JArray(Enumerable.Range(jointBase, joints.Count)),
                ["inverseBindMatrices"] = ibmAcc,
                ["skeleton"] = 0
            };

            // meshes
            foreach (var p in prims)
            {
                int n = p.Pos.Count;
                var pos = new List<float>(n * 3); var nrm = new List<float>(n * 3); var uv = new List<float>(n * 2);
                Vector3 mn = new Vector3(float.MaxValue, float.MaxValue, float.MaxValue), mx = -mn;
                for (int i = 0; i < n; i++)
                {
                    var v = CvP(p.Pos[i]); var nv = CvP(p.Nrm[i]).normalized;
                    pos.Add(v.x); pos.Add(v.y); pos.Add(v.z);
                    nrm.Add(nv.x); nrm.Add(nv.y); nrm.Add(nv.z);
                    uv.Add(p.Uv[i].x); uv.Add(1f - p.Uv[i].y);
                    mn = Vector3.Min(mn, v); mx = Vector3.Max(mx, v);
                }
                var jb = new byte[n * 8];
                for (int i = 0; i < n * 4; i++) { ushort j = (ushort)p.J[i]; jb[i * 2] = (byte)(j & 0xff); jb[i * 2 + 1] = (byte)(j >> 8); }
                var idx = new List<uint>(p.Idx.Count);
                for (int t = 0; t < p.Idx.Count; t += 3)
                {   // mirroring flips handedness -> flip winding
                    idx.Add((uint)p.Idx[t]); idx.Add((uint)p.Idx[t + 2]); idx.Add((uint)p.Idx[t + 1]);
                }
                var attrs = new JObject
                {
                    ["POSITION"] = bin.Accessor(Floats(pos), FLOAT, n, "VEC3", ARRAY_BUFFER, new JArray(mn.x, mn.y, mn.z), new JArray(mx.x, mx.y, mx.z)),
                    ["NORMAL"] = bin.Accessor(Floats(nrm), FLOAT, n, "VEC3", ARRAY_BUFFER),
                    ["TEXCOORD_0"] = bin.Accessor(Floats(uv), FLOAT, n, "VEC2", ARRAY_BUFFER),
                    ["JOINTS_0"] = bin.Accessor(jb, USHORT, n, "VEC4", ARRAY_BUFFER),
                    ["WEIGHTS_0"] = bin.Accessor(Floats(p.W), FLOAT, n, "VEC4", ARRAY_BUFFER)
                };
                var ib = new byte[idx.Count * 4];
                Buffer.BlockCopy(idx.ToArray(), 0, ib, 0, ib.Length);
                int idxAcc = bin.Accessor(ib, UINT, idx.Count, "SCALAR", ELEMENT_ARRAY_BUFFER);
                meshes.Add(new JObject
                {
                    ["name"] = p.Name,
                    ["primitives"] = new JArray(new JObject { ["attributes"] = attrs, ["indices"] = idxAcc, ["material"] = p.MaterialIndex, ["mode"] = 4 })
                });
                nodes.Add(new JObject { ["name"] = p.Name, ["mesh"] = meshes.Count - 1, ["skin"] = 0 });
                sceneNodes.Add(nodes.Count - 1);
            }
            rootNode["children"] = rootChildren;

            // images
            var imgs = new JArray(); var texs = new JArray();
            for (int i = 0; i < images.Count; i++)
            {
                imgs.Add(new JObject { ["bufferView"] = bin.View(images[i].Png, null), ["mimeType"] = "image/png", ["name"] = $"{name}_tex{i}" });
                texs.Add(new JObject { ["source"] = i, ["sampler"] = 0 });
            }

            while (bin.Data.Length % 4 != 0) bin.Data.WriteByte(0);
            var gltf = new JObject
            {
                ["asset"] = new JObject { ["version"] = "2.0", ["generator"] = "Uma2Roblox (UmaViewer)" },
                ["extensionsUsed"] = new JArray("KHR_materials_unlit"),
                ["scene"] = 0,
                ["scenes"] = new JArray(new JObject { ["name"] = name, ["nodes"] = sceneNodes }),
                ["nodes"] = nodes,
                ["meshes"] = meshes,
                ["skins"] = new JArray(skin),
                ["materials"] = materials,
                ["images"] = imgs,
                ["textures"] = texs,
                ["samplers"] = new JArray(new JObject { ["magFilter"] = 9729, ["minFilter"] = 9987, ["wrapS"] = 10497, ["wrapT"] = 10497 }),
                ["accessors"] = bin.Accessors,
                ["bufferViews"] = bin.Views,
                ["buffers"] = new JArray(new JObject { ["byteLength"] = bin.Data.Length })
            };

            byte[] json = Encoding.UTF8.GetBytes(gltf.ToString(Formatting.None));
            int jsonPad = (4 - json.Length % 4) % 4;
            byte[] binBytes = bin.Data.ToArray();
            int total = 12 + 8 + json.Length + jsonPad + 8 + binBytes.Length;
            using (var fs = new FileStream(path, FileMode.Create))
            using (var w = new BinaryWriter(fs))
            {
                w.Write(0x46546C67u); w.Write(2u); w.Write((uint)total);
                w.Write((uint)(json.Length + jsonPad)); w.Write(0x4E4F534Au); w.Write(json);
                for (int i = 0; i < jsonPad; i++) w.Write((byte)0x20);
                w.Write((uint)binBytes.Length); w.Write(0x004E4942u); w.Write(binBytes);
            }
        }

        static byte[] Floats(List<float> f)
        {
            var b = new byte[f.Count * 4];
            Buffer.BlockCopy(f.ToArray(), 0, b, 0, b.Length);
            return b;
        }

        static string[] Split(string csv) =>
            (csv ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim().ToLowerInvariant()).Where(s => s.Length > 0).ToArray();

        public static string Sanitize(string s)
        {
            var sb = new StringBuilder();
            foreach (char ch in s) sb.Append(char.IsLetterOrDigit(ch) || ch == '_' || ch == '-' ? ch : '_');
            return sb.Length == 0 ? "_" : sb.ToString();
        }
    }
}
