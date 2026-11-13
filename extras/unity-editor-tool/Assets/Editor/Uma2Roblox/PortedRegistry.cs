// Keeps track of which characters were already ported, and serves that list to the
// Roblox Studio plugin on http://localhost:34891 so Studio can report what it has imported.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Uma2Roblox
{
    [Serializable]
    public class PortedEntry
    {
        public int id;
        public string name;
        public string costume;
        public string glb;
        public string exportedAt;
        public bool imported;      // confirmed by the Studio plugin
        public string importedAt;
    }

    public class PortedRegistry
    {
        public const int Port = 34891;
        readonly object _lock = new object();
        Dictionary<string, PortedEntry> _entries = new Dictionary<string, PortedEntry>();
        string _path;

        // characters known to UmaViewer, snapshot taken on the main thread (for /status)
        public List<(int id, string name, List<string> costumes)> Catalog = new List<(int, string, List<string>)>();

        public static string Key(int id, string costume) => $"{id}_{costume}";

        public void Load(string outDir)
        {
            lock (_lock)
            {
                _path = Path.Combine(outDir, "ported.json");
                _entries = new Dictionary<string, PortedEntry>();
                if (File.Exists(_path))
                {
                    try { _entries = JsonConvert.DeserializeObject<Dictionary<string, PortedEntry>>(File.ReadAllText(_path)) ?? _entries; }
                    catch (Exception e) { Debug.LogWarning("[Uma2Roblox] could not read ported.json: " + e.Message); }
                }
            }
        }

        void SaveLocked()
        {
            if (_path == null) return;
            Directory.CreateDirectory(Path.GetDirectoryName(_path));
            File.WriteAllText(_path, JsonConvert.SerializeObject(_entries, Formatting.Indented));
        }

        public PortedEntry Get(int id, string costume)
        {
            lock (_lock) return _entries.TryGetValue(Key(id, costume), out var e) ? e : null;
        }

        public bool AnyFor(int id)
        {
            lock (_lock) return _entries.Values.Any(e => e.id == id);
        }

        public void MarkExported(int id, string name, string costume, string glb)
        {
            lock (_lock)
            {
                var k = Key(id, costume);
                if (!_entries.TryGetValue(k, out var e)) _entries[k] = e = new PortedEntry { id = id, costume = costume };
                e.name = name; e.glb = glb; e.exportedAt = DateTime.UtcNow.ToString("o");
                SaveLocked();
            }
        }

        public int MarkImported(IEnumerable<(int id, string costume)> items)
        {
            int n = 0;
            lock (_lock)
            {
                foreach (var (id, costume) in items)
                {
                    var k = Key(id, costume);
                    if (!_entries.TryGetValue(k, out var e))
                        _entries[k] = e = new PortedEntry { id = id, costume = costume, name = Catalog.FirstOrDefault(c => c.id == id).name };
                    if (!e.imported) { e.imported = true; e.importedAt = DateTime.UtcNow.ToString("o"); n++; }
                }
                SaveLocked();
            }
            return n;
        }

        public void Forget(int id, string costume)
        {
            lock (_lock) { _entries.Remove(Key(id, costume)); SaveLocked(); }
        }

        public string StatusJson()
        {
            lock (_lock)
            {
                var ported = new JArray(_entries.Values.OrderBy(e => e.id).Select(e => JObject.FromObject(e)));
                var unported = new JArray(Catalog
                    .Where(c => c.costumes.Count > 0 && !_entries.Values.Any(e => e.id == c.id))
                    .Select(c => new JObject { ["id"] = c.id, ["name"] = c.name, ["costumes"] = new JArray(c.costumes) }));
                return new JObject { ["ported"] = ported, ["unported"] = unported }.ToString(Formatting.None);
            }
        }

        // ------------------------------------------------------------ tiny local HTTP server
        HttpListener _http;
        Thread _thread;
        public bool ServerRunning => _http != null && _http.IsListening;
        public event Action Changed;   // raised on the listener thread

        public void StartServer()
        {
            if (ServerRunning) return;
            try
            {
                _http = new HttpListener();
                _http.Prefixes.Add($"http://localhost:{Port}/");
                _http.Prefixes.Add($"http://127.0.0.1:{Port}/");
                _http.Start();
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[Uma2Roblox] Could not start sync server on port {Port}: {e.Message}");
                _http = null;
                return;
            }
            _thread = new Thread(Loop) { IsBackground = true, Name = "Uma2Roblox sync" };
            _thread.Start();
            Debug.Log($"[Uma2Roblox] Studio sync server listening on http://localhost:{Port}/uma2roblox/status");
        }

        public void StopServer()
        {
            try { _http?.Stop(); _http?.Close(); } catch { }
            _http = null;
        }

        void Loop()
        {
            while (_http != null && _http.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = _http.GetContext(); } catch { break; }
                try { Handle(ctx); }
                catch (Exception e) { Respond(ctx, 500, new JObject { ["error"] = e.Message }.ToString()); }
            }
        }

        void Handle(HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath.TrimEnd('/');
            if (ctx.Request.HttpMethod == "GET" && path == "/uma2roblox/status")
            {
                Respond(ctx, 200, StatusJson());
                return;
            }
            if (ctx.Request.HttpMethod == "POST" && path == "/uma2roblox/imported")
            {
                string body;
                using (var r = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)) body = r.ReadToEnd();
                var j = JObject.Parse(body);
                var items = (j["models"] as JArray ?? new JArray())
                    .Select(m => ((int)m["id"], (string)m["costume"] ?? "00")).ToList();
                int n = MarkImported(items);
                Changed?.Invoke();
                Respond(ctx, 200, new JObject { ["marked"] = n }.ToString(Formatting.None));
                return;
            }
            Respond(ctx, 404, "{\"error\":\"not found\"}");
        }

        static void Respond(HttpListenerContext ctx, int code, string json)
        {
            var b = Encoding.UTF8.GetBytes(json);
            ctx.Response.StatusCode = code;
            ctx.Response.ContentType = "application/json";
            ctx.Response.ContentLength64 = b.Length;
            ctx.Response.OutputStream.Write(b, 0, b.Length);
            ctx.Response.OutputStream.Close();
        }
    }
}
