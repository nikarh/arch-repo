/*
 * pwtool - PipeWire audio status tool
 *
 * Monitors default audio sink or source, outputs JSON for waybar or
 * i3status-rs. Replaces pa-input.sh / pa-output.sh shell scripts.
 *
 * Usage: pwtool [--i3statusrs] [--debug] <sink|source>
 */
#include <pipewire/extensions/metadata.h>
#include <pipewire/pipewire.h>
#include <spa/param/props.h>
#include <spa/pod/iter.h>
#include <spa/pod/parser.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── name remapping ──────────────────────────────────────────────── */

struct name_map {
  char *key;
  char *value;
  struct name_map *next;
};

/* ── per-node tracking ───────────────────────────────────────────── */

struct state;

struct node_info {
  uint32_t id;
  char *name;        /* node.name  (metadata matching) */
  char *description; /* node.description (display) */
  char *media_class; /* media.class */
  bool muted;
  bool subscribed; /* param subscription active */
  struct pw_proxy *proxy;
  struct spa_hook node_listener;
  struct spa_hook proxy_listener;
  struct state *state;
  struct node_info *next;
};

/* ── global state ────────────────────────────────────────────────── */

struct state {
  struct pw_main_loop *loop;
  struct pw_context *context;
  struct pw_core *core;
  struct pw_registry *registry;
  struct spa_hook registry_listener;
  struct spa_hook core_listener;

  /* metadata */
  struct pw_proxy *metadata;
  struct spa_hook metadata_listener;

  /* default device names from metadata */
  char default_sink_name[512];
  char default_source_name[512];

  /* linked list of tracked nodes */
  struct node_info *nodes;

  /* config name remapping */
  struct name_map *sink_map;
  struct name_map *source_map;

  /* mode: true = source, false = sink */
  bool source_mode;

  /* output mode */
  bool i3statusrs;
  bool debug;

  /* roundtrip sync */
  int pending_seq;
  bool initial_sync_done;

  /* output dedup */
  char last_output[2048];
};

/* ── forward declarations ────────────────────────────────────────── */

static void output_status(struct state *s);
static void subscribe_default_node(struct state *s);

/* ── helpers ─────────────────────────────────────────────────────── */

static const char *map_name(const struct name_map *map, const char *desc) {
  for (const struct name_map *m = map; m; m = m->next)
    if (strcmp(m->key, desc) == 0)
      return m->value;
  return desc;
}

static void free_map(struct name_map *m) {
  while (m) {
    struct name_map *next = m->next;
    free(m->key);
    free(m->value);
    free(m);
    m = next;
  }
}

/* ── config parser ───────────────────────────────────────────────── */

/*
 * Config format (~/.config/pwtool/config):
 *   [sink]
 *   "key with spaces" = "value"
 *   [source]
 *   "key" = "value"
 *
 * Supports \" escape inside quoted strings.
 */

static char *parse_quoted(const char **p) {
  if (**p != '"')
    return NULL;
  (*p)++; /* skip opening quote */

  size_t cap = 64, len = 0;
  char *buf = malloc(cap);
  if (!buf)
    return NULL;

  while (**p && **p != '"') {
    if (**p == '\\' && *(*p + 1) == '"') {
      (*p)++; /* skip backslash */
    }
    if (len + 1 >= cap) {
      cap *= 2;
      char *tmp = realloc(buf, cap);
      if (!tmp) {
        free(buf);
        return NULL;
      }
      buf = tmp;
    }
    buf[len++] = **p;
    (*p)++;
  }
  if (**p == '"')
    (*p)++;
  buf[len] = '\0';
  return buf;
}

static void load_config(struct state *s) {
  const char *home = getenv("HOME");
  if (!home)
    return;

  char path[512];
  snprintf(path, sizeof(path), "%s/.config/pwtool/config", home);

  FILE *f = fopen(path, "r");
  if (!f)
    return;

  struct name_map **current = NULL;
  char line[1024];

  while (fgets(line, sizeof(line), f)) {
    /* strip trailing newline */
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
      line[--len] = '\0';

    /* skip blank lines and comments */
    const char *p = line;
    while (*p == ' ' || *p == '\t')
      p++;
    if (*p == '\0' || *p == '#')
      continue;

    /* section header */
    if (*p == '[') {
      if (strncmp(p, "[sink]", 6) == 0)
        current = &s->sink_map;
      else if (strncmp(p, "[source]", 8) == 0)
        current = &s->source_map;
      else
        current = NULL;
      continue;
    }

    if (!current)
      continue;

    /* "key" = "value" */
    char *key = parse_quoted(&p);
    if (!key)
      continue;

    /* skip whitespace and = */
    while (*p == ' ' || *p == '\t')
      p++;
    if (*p != '=') {
      free(key);
      continue;
    }
    p++;
    while (*p == ' ' || *p == '\t')
      p++;

    char *value = parse_quoted(&p);
    if (!value) {
      free(key);
      continue;
    }

    struct name_map *entry = calloc(1, sizeof(*entry));
    entry->key = key;
    entry->value = value;
    entry->next = *current;
    *current = entry;
  }
  fclose(f);

  if (s->debug) {
    fprintf(stderr, "[config] loaded from %s\n", path);
    for (const struct name_map *m = s->sink_map; m; m = m->next)
      fprintf(stderr, "[config] sink: \"%s\" -> \"%s\"\n", m->key, m->value);
    for (const struct name_map *m = s->source_map; m; m = m->next)
      fprintf(stderr, "[config] source: \"%s\" -> \"%s\"\n", m->key, m->value);
  }
}

/* ── JSON output ─────────────────────────────────────────────────── */

static void json_escape(const char *in, char *out, size_t out_size) {
  size_t j = 0;
  for (size_t i = 0; in[i] && j + 6 < out_size; i++) {
    unsigned char c = (unsigned char)in[i];
    if (c == '"') {
      out[j++] = '\\';
      out[j++] = '"';
    } else if (c == '\\') {
      out[j++] = '\\';
      out[j++] = '\\';
    } else if (c < 0x20) {
      j += snprintf(out + j, out_size - j, "\\u%04x", c);
    } else {
      out[j++] = c;
    }
  }
  out[j] = '\0';
}

static void output_status(struct state *s) {
  /* find current default node */
  const char *target_name =
      s->source_mode ? s->default_source_name : s->default_sink_name;

  struct node_info *def = NULL;
  bool is_monitor = false;
  if (target_name[0]) {
    for (struct node_info *n = s->nodes; n; n = n->next) {
      if (n->name && strcmp(n->name, target_name) == 0) {
        const char *mc = n->media_class;
        if (s->source_mode && mc && strcmp(mc, "Audio/Source") == 0) {
          def = n;
          break;
        }
        if (!s->source_mode && mc && strcmp(mc, "Audio/Sink") == 0) {
          def = n;
          break;
        }
      }
    }
    /* in source mode, default source may point to a sink (monitor) */
    if (!def && s->source_mode) {
      for (struct node_info *n = s->nodes; n; n = n->next) {
        if (n->name && strcmp(n->name, target_name) == 0 && n->media_class &&
            strcmp(n->media_class, "Audio/Sink") == 0) {
          def = n;
          is_monitor = true;
          break;
        }
      }
    }
  }

  /* determine state based on active streams */
  const char *state_str;
  if (!def) {
    state_str = "idle";
  } else {
    /* count active streams */
    const char *stream_class =
        s->source_mode ? "Stream/Input/Audio" : "Stream/Output/Audio";
    bool has_streams = false;
    for (struct node_info *n = s->nodes; n; n = n->next) {
      if (n->media_class && strcmp(n->media_class, stream_class) == 0) {
        has_streams = true;
        break;
      }
    }
    state_str = has_streams ? "critical" : "info";
  }

  /* get display name */
  const char *display = "";
  char monitor_buf[1024];
  if (def && def->description) {
    const char *desc = def->description;
    if (is_monitor) {
      snprintf(monitor_buf, sizeof(monitor_buf), "Monitor of %s", desc);
      desc = monitor_buf;
    }
    const struct name_map *map = s->source_mode ? s->source_map : s->sink_map;
    display = map_name(map, desc);
  }

  bool muted = def ? def->muted : false;

  char escaped_name[1024];
  json_escape(display, escaped_name, sizeof(escaped_name));

  char buf[2048];
  if (s->i3statusrs) {
    const char *icon = s->source_mode ? "microphone" : "headphones";
    snprintf(buf, sizeof(buf),
             "{\"text\":\"%s\",\"icon\":\"%s\",\"state\":\"%s\"}", escaped_name,
             icon, state_str);
  } else {
    const char *icon;
    if (s->source_mode)
      icon = muted ? "\xef\x84\xb1" : "\xef\x84\xb0"; /* U+F131 : U+F130 */
    else
      icon = muted ? "\xf3\xb0\x9f\x8e"
                   : "\xf3\xb0\x8b\x8b"; /* U+F07CE : U+F02CB */

    char escaped_icon[64];
    json_escape(icon, escaped_icon, sizeof(escaped_icon));

    snprintf(buf, sizeof(buf), "{\"text\":\"%s %s\",\"class\":\"%s\"}",
             escaped_icon, escaped_name, state_str);
  }

  /* dedup: only emit if output changed */
  if (strcmp(buf, s->last_output) == 0)
    return;
  memcpy(s->last_output, buf, strlen(buf) + 1);

  puts(buf);
  fflush(stdout);
}

/* ── node events ─────────────────────────────────────────────────── */

static bool is_current_default(struct node_info *ni) {
  struct state *s = ni->state;
  const char *target =
      s->source_mode ? s->default_source_name : s->default_sink_name;
  return ni->name && target[0] && strcmp(ni->name, target) == 0;
}

static void node_event_info(void *data, const struct pw_node_info *info) {
  struct node_info *ni = data;
  struct state *s = ni->state;

  if (info->change_mask & PW_NODE_CHANGE_MASK_PROPS && info->props) {
    const char *desc = spa_dict_lookup(info->props, PW_KEY_NODE_DESCRIPTION);
    if (desc) {
      free(ni->description);
      ni->description = strdup(desc);
    }
    const char *name = spa_dict_lookup(info->props, PW_KEY_NODE_NAME);
    if (name) {
      free(ni->name);
      ni->name = strdup(name);
    }
  }

  /* only output if this is the current default node */
  if (s->initial_sync_done && is_current_default(ni))
    output_status(s);
}

static void node_event_param(void *data, int seq, uint32_t id, uint32_t index,
                             uint32_t next, const struct spa_pod *param) {
  struct node_info *ni = data;
  struct state *s = ni->state;

  if (!param || id != SPA_PARAM_Props)
    return;

  /* iterate props object looking for SPA_PROP_mute */
  if (SPA_POD_TYPE(param) != SPA_TYPE_Object)
    return;

  const struct spa_pod_object *obj = (const struct spa_pod_object *)param;
  const struct spa_pod_prop *prop;

  SPA_POD_OBJECT_FOREACH(obj, prop) {
    if (prop->key == SPA_PROP_mute) {
      bool muted = false;
      spa_pod_get_bool(&prop->value, &muted);
      if (ni->muted != muted) {
        ni->muted = muted;
        if (s->debug)
          fprintf(stderr, "[node %u] mute -> %s\n", ni->id,
                  muted ? "true" : "false");
        if (s->initial_sync_done)
          output_status(s);
      }
      break;
    }
  }
}

static const struct pw_node_events node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = node_event_info,
    .param = node_event_param,
};

/* ── proxy events (for cleanup on destroy) ───────────────────────── */

static void proxy_destroy(void *data) {
  struct node_info *ni = data;
  spa_hook_remove(&ni->node_listener);
  spa_hook_remove(&ni->proxy_listener);
  ni->proxy = NULL;
}

static const struct pw_proxy_events proxy_events = {
    PW_VERSION_PROXY_EVENTS,
    .destroy = proxy_destroy,
};

/* ── subscribe to params on the current default node ─────────────── */

static void subscribe_default_node(struct state *s) {
  const char *target_name =
      s->source_mode ? s->default_source_name : s->default_sink_name;
  for (struct node_info *n = s->nodes; n; n = n->next) {
    bool class_match =
        n->media_class &&
        (strcmp(n->media_class, "Audio/Sink") == 0 ||
         (s->source_mode && strcmp(n->media_class, "Audio/Source") == 0));
    bool is_target = n->name && target_name[0] &&
                     strcmp(n->name, target_name) == 0 && class_match;

    if (is_target && !n->subscribed && n->proxy) {
      uint32_t params[] = {SPA_PARAM_Props};
      pw_node_subscribe_params((struct pw_node *)n->proxy, params, 1);
      n->subscribed = true;
      if (s->debug)
        fprintf(stderr, "[subscribe] node %u (%s)\n", n->id, n->name);
    }
  }
}

/* ── registry events ─────────────────────────────────────────────── */

static bool is_tracked_class(const char *mc, bool source_mode) {
  if (!mc)
    return false;
  if (strcmp(mc, "Audio/Sink") == 0 || strcmp(mc, "Audio/Source") == 0)
    return true;
  /* only track the stream class relevant to our mode */
  if (source_mode)
    return strcmp(mc, "Stream/Input/Audio") == 0;
  else
    return strcmp(mc, "Stream/Output/Audio") == 0;
}

static void registry_global(void *data, uint32_t id, uint32_t permissions,
                            const char *type, uint32_t version,
                            const struct spa_dict *props) {
  struct state *s = data;

  /* handle metadata object */
  if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0 && !s->metadata) {
    if (props) {
      const char *name = spa_dict_lookup(props, PW_KEY_METADATA_NAME);
      if (name && strcmp(name, "default") != 0)
        return;
    }
    s->metadata = pw_registry_bind(s->registry, id, PW_TYPE_INTERFACE_Metadata,
                                   PW_VERSION_METADATA, 0);
    if (s->debug)
      fprintf(stderr, "[metadata] bound id=%u\n", id);
    return;
  }

  /* handle nodes */
  if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
    return;

  if (!props)
    return;
  const char *mc = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
  if (!is_tracked_class(mc, s->source_mode))
    return;

  struct node_info *ni = calloc(1, sizeof(*ni));
  ni->id = id;
  ni->state = s;

  const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
  if (name)
    ni->name = strdup(name);

  const char *desc = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
  if (desc)
    ni->description = strdup(desc);

  ni->media_class = strdup(mc);

  /* only bind proxy for sink/source nodes (need params for mute) */
  if (strcmp(mc, "Audio/Sink") == 0 || strcmp(mc, "Audio/Source") == 0) {
    ni->proxy = pw_registry_bind(s->registry, id, PW_TYPE_INTERFACE_Node,
                                 PW_VERSION_NODE, 0);
    if (ni->proxy) {
      pw_proxy_add_listener(ni->proxy, &ni->proxy_listener, &proxy_events, ni);
      pw_node_add_listener((struct pw_node *)ni->proxy, &ni->node_listener,
                           &node_events, ni);
    }
  }

  /* prepend to list */
  ni->next = s->nodes;
  s->nodes = ni;

  if (s->debug)
    fprintf(stderr, "[node +] id=%u class=%s name=%s desc=%s\n", id, mc,
            name ? name : "(null)", desc ? desc : "(null)");

  if (s->initial_sync_done) {
    subscribe_default_node(s);
    output_status(s);
  }
}

static void registry_global_remove(void *data, uint32_t id) {
  struct state *s = data;
  struct node_info **pp = &s->nodes;

  while (*pp) {
    struct node_info *n = *pp;
    if (n->id == id) {
      *pp = n->next;
      if (s->debug)
        fprintf(stderr, "[node -] id=%u name=%s\n", id,
                n->name ? n->name : "(null)");
      if (n->proxy)
        pw_proxy_destroy(n->proxy);
      free(n->name);
      free(n->description);
      free(n->media_class);
      free(n);
      if (s->initial_sync_done)
        output_status(s);
      return;
    }
    pp = &n->next;
  }
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_global,
    .global_remove = registry_global_remove,
};

/* ── metadata events ─────────────────────────────────────────────── */

/*
 * Metadata value for default.audio.sink is JSON like: {"name":"alsa_output..."}
 * Minimal parser: find "name":" then extract the value.
 */
static void extract_metadata_name(const char *json, char *out,
                                  size_t out_size) {
  out[0] = '\0';
  if (!json)
    return;

  const char *key = "\"name\":\"";
  const char *p = strstr(json, key);
  if (!p)
    return;
  p += strlen(key);

  size_t i = 0;
  while (*p && *p != '"' && i + 1 < out_size) {
    if (*p == '\\' && *(p + 1)) {
      p++;
    }
    out[i++] = *p++;
  }
  out[i] = '\0';
}

static int metadata_property(void *data, uint32_t subject, const char *key,
                             const char *type, const char *value) {
  struct state *s = data;

  if (subject != 0 || !key)
    return 0;

  bool changed = false;

  if (strcmp(key, "default.audio.sink") == 0) {
    char old[512];
    strncpy(old, s->default_sink_name, sizeof(old));
    old[sizeof(old) - 1] = '\0';
    extract_metadata_name(value, s->default_sink_name,
                          sizeof(s->default_sink_name));
    changed = strcmp(old, s->default_sink_name) != 0;
    if (s->debug && changed)
      fprintf(stderr, "[metadata] default.audio.sink = %s\n",
              s->default_sink_name);
  } else if (strcmp(key, "default.audio.source") == 0) {
    char old[512];
    strncpy(old, s->default_source_name, sizeof(old));
    old[sizeof(old) - 1] = '\0';
    extract_metadata_name(value, s->default_source_name,
                          sizeof(s->default_source_name));
    changed = strcmp(old, s->default_source_name) != 0;
    if (s->debug && changed)
      fprintf(stderr, "[metadata] default.audio.source = %s\n",
              s->default_source_name);
  }

  if (changed && s->initial_sync_done) {
    subscribe_default_node(s);
    output_status(s);
  }

  return 0;
}

static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = metadata_property,
};

/* ── core events (for roundtrip sync) ────────────────────────────── */

static void core_done(void *data, uint32_t id, int seq) {
  struct state *s = data;

  if (id != PW_ID_CORE || seq != s->pending_seq)
    return;

  if (!s->initial_sync_done) {
    s->initial_sync_done = true;
    if (s->debug)
      fprintf(stderr, "[core] initial sync done\n");

    /* now add metadata listener if we have metadata */
    if (s->metadata) {
      pw_metadata_add_listener((struct pw_metadata *)s->metadata,
                               &s->metadata_listener, &metadata_events, s);
    }

    /* subscribe to default node params after a second roundtrip
     * so metadata events have been processed */
    s->pending_seq = pw_core_sync(s->core, PW_ID_CORE, 0);
  } else {
    /* second sync: metadata has been processed */
    subscribe_default_node(s);
    output_status(s);
  }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = core_done,
};

/* ── main ────────────────────────────────────────────────────────── */

static void usage(const char *prog) {
  fprintf(stderr, "Usage: %s [--i3statusrs] [--debug] <sink|source>\n", prog);
  exit(1);
}

int main(int argc, char *argv[]) {
  struct state s = {0};

  /* parse args */
  bool got_mode = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--i3statusrs") == 0) {
      s.i3statusrs = true;
    } else if (strcmp(argv[i], "--debug") == 0) {
      s.debug = true;
    } else if (strcmp(argv[i], "sink") == 0) {
      s.source_mode = false;
      got_mode = true;
    } else if (strcmp(argv[i], "source") == 0) {
      s.source_mode = true;
      got_mode = true;
    } else {
      usage(argv[0]);
    }
  }
  if (!got_mode)
    usage(argv[0]);

  load_config(&s);

  pw_init(&argc, &argv);

  s.loop = pw_main_loop_new(NULL);
  s.context = pw_context_new(pw_main_loop_get_loop(s.loop), NULL, 0);
  s.core = pw_context_connect(s.context, NULL, 0);
  if (!s.core) {
    fprintf(stderr, "error: can't connect to PipeWire\n");
    return 1;
  }

  pw_core_add_listener(s.core, &s.core_listener, &core_events, &s);

  s.registry = pw_core_get_registry(s.core, PW_VERSION_REGISTRY, 0);
  pw_registry_add_listener(s.registry, &s.registry_listener, &registry_events,
                           &s);

  /* trigger roundtrip to wait for initial globals */
  s.pending_seq = pw_core_sync(s.core, PW_ID_CORE, 0);

  pw_main_loop_run(s.loop);

  /* cleanup */
  while (s.nodes) {
    struct node_info *n = s.nodes;
    s.nodes = n->next;
    if (n->proxy)
      pw_proxy_destroy(n->proxy);
    free(n->name);
    free(n->description);
    free(n->media_class);
    free(n);
  }

  if (s.metadata)
    pw_proxy_destroy(s.metadata);
  pw_proxy_destroy((struct pw_proxy *)s.registry);
  pw_core_disconnect(s.core);
  pw_context_destroy(s.context);
  pw_main_loop_destroy(s.loop);
  pw_deinit();

  free_map(s.sink_map);
  free_map(s.source_map);

  return 0;
}
