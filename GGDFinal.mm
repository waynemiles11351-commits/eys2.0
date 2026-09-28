#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <vector>
#include <algorithm>

// GGD Identity Overlay v3
// Target: com.seayoo.ggd / 1.1.13 / arm64 / iOS 18+
// Design goals:
// 1) Constructor only installs a lightweight UIKit overlay. No Unity/IL2CPP calls at load time.
// 2) Runtime probing is opt-in from the panel and only runs after the app is fully alive.
// 3) Never read unknown-sized managed fields into fixed-size buffers.
// 4) Read List<T> through managed get_Count/get_Item rather than raw List offsets.
// 5) Overlay only accepts touches inside the small control area; all other game touches pass through.
// 6) Position rendering is enabled only after managed player data is successfully read.

struct Il2CppDomain;
struct Il2CppThread;
struct Il2CppAssembly;
struct Il2CppImage;
struct Il2CppClass;
struct FieldInfo;
struct MethodInfo;
struct Il2CppObject;
struct Il2CppType;
struct Il2CppString;

struct GGDVector3 { float x, y, z; };

using t_domain_get                = Il2CppDomain* (*)();
using t_thread_attach             = Il2CppThread* (*)(Il2CppDomain*);
using t_domain_get_assemblies     = const Il2CppAssembly** (*)(Il2CppDomain*, size_t*);
using t_assembly_get_image        = const Il2CppImage* (*)(const Il2CppAssembly*);
using t_image_get_name            = const char* (*)(const Il2CppImage*);
using t_image_get_class_count     = size_t (*)(const Il2CppImage*);
using t_image_get_class           = Il2CppClass* (*)(const Il2CppImage*, size_t);
using t_class_from_name           = Il2CppClass* (*)(const Il2CppImage*, const char*, const char*);
using t_class_get_name            = const char* (*)(Il2CppClass*);
using t_class_get_namespace       = const char* (*)(Il2CppClass*);
using t_class_get_parent          = Il2CppClass* (*)(Il2CppClass*);
using t_class_get_fields          = FieldInfo* (*)(Il2CppClass*, void**);
using t_class_get_field_from_name = FieldInfo* (*)(Il2CppClass*, const char*);
using t_class_get_method          = const MethodInfo* (*)(Il2CppClass*, const char*, int);
using t_class_is_enum             = bool (*)(Il2CppClass*);
using t_field_get_flags           = uint32_t (*)(FieldInfo*);
using t_field_get_name            = const char* (*)(FieldInfo*);
using t_field_get_type            = const Il2CppType* (*)(FieldInfo*);
using t_field_static_get_value    = void (*)(FieldInfo*, void*);
using t_field_get_value            = void (*)(Il2CppObject*, FieldInfo*, void*);
using t_type_get_name             = const char* (*)(const Il2CppType*);
using t_type_get_class             = Il2CppClass* (*)(const Il2CppType*);
using t_type_get_type              = uint32_t (*)(const Il2CppType*);
using t_object_get_class           = Il2CppClass* (*)(Il2CppObject*);
using t_object_unbox               = void* (*)(Il2CppObject*);
using t_runtime_invoke             = Il2CppObject* (*)(const MethodInfo*, void*, void**, Il2CppObject**);
using t_string_length              = int32_t (*)(Il2CppString*);
using t_string_chars               = const uint16_t* (*)(Il2CppString*);

static constexpr uint32_t FIELD_ATTRIBUTE_STATIC  = 0x0010;
static constexpr uint32_t FIELD_ATTRIBUTE_LITERAL = 0x0040;
static constexpr uint32_t IL2CPP_TYPE_BOOLEAN = 2;
static constexpr uint32_t IL2CPP_TYPE_I1 = 4;
static constexpr uint32_t IL2CPP_TYPE_U1 = 5;
static constexpr uint32_t IL2CPP_TYPE_I2 = 6;
static constexpr uint32_t IL2CPP_TYPE_U2 = 7;
static constexpr uint32_t IL2CPP_TYPE_I4 = 8;
static constexpr uint32_t IL2CPP_TYPE_U4 = 9;
static constexpr uint32_t IL2CPP_TYPE_I8 = 10;
static constexpr uint32_t IL2CPP_TYPE_U8 = 11;
static constexpr uint32_t IL2CPP_TYPE_STRING = 14;
static constexpr uint32_t IL2CPP_TYPE_CLASS = 18;
static constexpr uint32_t IL2CPP_TYPE_OBJECT = 28;
static constexpr uint32_t IL2CPP_TYPE_SZARRAY = 29;

static bool ciContains(const char *s, const char *needle) {
    if (!s || !needle || !*needle) return false;
    size_t n = strlen(s), m = strlen(needle);
    if (n < m) return false;
    for (size_t i = 0; i + m <= n; ++i) {
        bool ok = true;
        for (size_t j = 0; j < m; ++j) {
            char a = s[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a = char(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = char(b - 'A' + 'a');
            if (a != b) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

static bool nameEqualsAny(const char *name, const char *const *candidates) {
    if (!name) return false;
    for (size_t i = 0; candidates[i]; ++i) if (strcmp(name, candidates[i]) == 0) return true;
    return false;
}

struct GGDIl2CppAPI {
    t_domain_get domain_get = nullptr;
    t_thread_attach thread_attach = nullptr;
    t_domain_get_assemblies domain_get_assemblies = nullptr;
    t_assembly_get_image assembly_get_image = nullptr;
    t_image_get_name image_get_name = nullptr;
    t_image_get_class_count image_get_class_count = nullptr;
    t_image_get_class image_get_class = nullptr;
    t_class_from_name class_from_name = nullptr;
    t_class_get_name class_get_name = nullptr;
    t_class_get_namespace class_get_namespace = nullptr;
    t_class_get_parent class_get_parent = nullptr;
    t_class_get_fields class_get_fields = nullptr;
    t_class_get_field_from_name class_get_field_from_name = nullptr;
    t_class_get_method class_get_method = nullptr;
    t_class_is_enum class_is_enum = nullptr;
    t_field_get_flags field_get_flags = nullptr;
    t_field_get_name field_get_name = nullptr;
    t_field_get_type field_get_type = nullptr;
    t_field_static_get_value field_static_get_value = nullptr;
    t_field_get_value field_get_value = nullptr;
    t_type_get_name type_get_name = nullptr;
    t_type_get_class type_get_class = nullptr;
    t_type_get_type type_get_type = nullptr;
    t_object_get_class object_get_class = nullptr;
    t_object_unbox object_unbox = nullptr;
    t_runtime_invoke runtime_invoke = nullptr;
    t_string_length string_length = nullptr;
    t_string_chars string_chars = nullptr;

    template <typename T>
    bool resolveOne(T &slot, const char *symbol) {
        void *p = dlsym(RTLD_DEFAULT, symbol);
        slot = reinterpret_cast<T>(p);
        return p != nullptr;
    }

    bool resolve() {
#define R(x) if (!resolveOne(x, #x)) return false
        R(domain_get);
        R(thread_attach);
        R(domain_get_assemblies);
        R(assembly_get_image);
        R(image_get_name);
        R(image_get_class_count);
        R(image_get_class);
        R(class_from_name);
        R(class_get_name);
        R(class_get_namespace);
        R(class_get_parent);
        R(class_get_fields);
        R(class_get_field_from_name);
        R(class_get_method);
        R(class_is_enum);
        R(field_get_flags);
        R(field_get_name);
        R(field_get_type);
        R(field_static_get_value);
        R(field_get_value);
        R(type_get_name);
        R(type_get_class);
        R(type_get_type);
        R(object_get_class);
        R(object_unbox);
        R(runtime_invoke);
        R(string_length);
        R(string_chars);
#undef R
        return true;
    }

    bool attach() {
        if (!domain_get || !thread_attach) return false;
        Il2CppDomain *d = domain_get();
        if (!d) return false;
        return thread_attach(d) != nullptr;
    }

    std::vector<const Il2CppImage*> images() const {
        std::vector<const Il2CppImage*> out;
        Il2CppDomain *d = domain_get ? domain_get() : nullptr;
        if (!d) return out;
        size_t count = 0;
        const Il2CppAssembly **assemblies = domain_get_assemblies ? domain_get_assemblies(d, &count) : nullptr;
        if (!assemblies || count > 4096) return out;
        out.reserve(count);
        for (size_t i = 0; i < count; ++i) {
            if (!assemblies[i]) continue;
            const Il2CppImage *img = assembly_get_image(assemblies[i]);
            if (img) out.push_back(img);
        }
        return out;
    }

    Il2CppClass *findClass(const char *name, const char *ns) const {
        if (!name || !class_from_name) return nullptr;
        auto imgs = images();
        for (const Il2CppImage *img : imgs) {
            Il2CppClass *c = class_from_name(img, ns ? ns : "", name);
            if (c) return c;
        }
        return nullptr;
    }

    Il2CppClass *findClassAnyNamespace(const char *name) const {
        if (!name) return nullptr;
        static const char *const namespaces[] = { "", "Goose", "Goose.Ctls", "UnityEngine", "UnityEngine.UI", nullptr };
        auto imgs = images();
        for (const Il2CppImage *img : imgs) {
            for (int i = 0; namespaces[i]; ++i) {
                Il2CppClass *c = class_from_name(img, namespaces[i], name);
                if (c) return c;
            }
        }
        return nullptr;
    }

    NSString *toNSString(Il2CppString *s) const {
        if (!s || !string_length || !string_chars) return nil;
        int32_t len = string_length(s);
        if (len <= 0 || len > 2048) return nil;
        const uint16_t *chars = string_chars(s);
        if (!chars) return nil;
        return [[NSString alloc] initWithCharacters:(const unichar *)chars length:(NSUInteger)len];
    }
};

static FieldInfo *findFieldInHierarchy(GGDIl2CppAPI &api, Il2CppClass *klass, const char *const *names, bool wantStatic) {
    for (int depth = 0; klass && depth < 12; ++depth) {
        for (size_t i = 0; names[i]; ++i) {
            FieldInfo *f = api.class_get_field_from_name(klass, names[i]);
            if (!f) continue;
            uint32_t flags = api.field_get_flags(f);
            bool isStatic = (flags & FIELD_ATTRIBUTE_STATIC) != 0;
            if (isStatic == wantStatic) return f;
        }
        klass = api.class_get_parent ? api.class_get_parent(klass) : nullptr;
    }
    return nullptr;
}

static const MethodInfo *findMethodInHierarchy(GGDIl2CppAPI &api, Il2CppClass *klass, const char *name, int argc) {
    for (int depth = 0; klass && depth < 12; ++depth) {
        const MethodInfo *m = api.class_get_method(klass, name, argc);
        if (m) return m;
        klass = api.class_get_parent ? api.class_get_parent(klass) : nullptr;
    }
    return nullptr;
}

static bool isStringField(GGDIl2CppAPI &api, FieldInfo *f) {
    if (!f) return false;
    const Il2CppType *t = api.field_get_type(f);
    if (!t) return false;
    uint32_t ty = api.type_get_type(t);
    if (ty == IL2CPP_TYPE_STRING) return true;
    const char *name = api.type_get_name(t);
    return name && strcmp(name, "System.String") == 0;
}

static bool isReferenceType(GGDIl2CppAPI &api, const Il2CppType *t) {
    if (!t) return false;
    uint32_t ty = api.type_get_type(t);
    return ty == IL2CPP_TYPE_CLASS || ty == IL2CPP_TYPE_OBJECT || ty == IL2CPP_TYPE_STRING || ty == IL2CPP_TYPE_SZARRAY;
}

static bool readManagedInt(GGDIl2CppAPI &api, Il2CppObject *obj, FieldInfo *f, int64_t *out) {
    if (!obj || !f || !out) return false;
    const Il2CppType *t = api.field_get_type(f);
    if (!t) return false;
    uint32_t ty = api.type_get_type(t);
    uint32_t size = 0;
    switch (ty) {
        case IL2CPP_TYPE_I1: size = 1; break;
        case IL2CPP_TYPE_U1: size = 1; break;
        case IL2CPP_TYPE_I2: size = 2; break;
        case IL2CPP_TYPE_U2: size = 2; break;
        case IL2CPP_TYPE_I4: size = 4; break;
        case IL2CPP_TYPE_U4: size = 4; break;
        case IL2CPP_TYPE_I8: size = 8; break;
        case IL2CPP_TYPE_U8: size = 8; break;
        default: break;
    }
    if (!size) {
        Il2CppClass *tc = api.type_get_class ? api.type_get_class(t) : nullptr;
        if (!tc || !api.class_is_enum || !api.class_is_enum(tc)) return false;
        // C# enums default to Int32; only read four bytes unless metadata says otherwise.
        size = 4;
    }

    uint8_t buf[8] = {0};
    api.field_get_value(obj, f, buf);
    if (ty == IL2CPP_TYPE_I1) *out = *(int8_t*)buf;
    else if (ty == IL2CPP_TYPE_U1) *out = *(uint8_t*)buf;
    else if (ty == IL2CPP_TYPE_I2) *out = *(int16_t*)buf;
    else if (ty == IL2CPP_TYPE_U2) *out = *(uint16_t*)buf;
    else if (ty == IL2CPP_TYPE_I4) *out = *(int32_t*)buf;
    else if (ty == IL2CPP_TYPE_U4) *out = *(uint32_t*)buf;
    else if (ty == IL2CPP_TYPE_I8) *out = *(int64_t*)buf;
    else if (ty == IL2CPP_TYPE_U8) *out = (int64_t)*(uint64_t*)buf;
    else *out = *(int32_t*)buf;
    return true;
}

static NSString *readStringField(GGDIl2CppAPI &api, Il2CppObject *obj, Il2CppClass *klass, const char *const *names) {
    FieldInfo *f = findFieldInHierarchy(api, klass, names, false);
    if (!f || !isStringField(api, f)) return nil;
    Il2CppString *s = nullptr;
    api.field_get_value(obj, f, &s);
    return api.toNSString(s);
}

static NSString *readStringGetter(GGDIl2CppAPI &api, Il2CppObject *obj, Il2CppClass *klass, const char *const *getters) {
    for (size_t i = 0; getters[i]; ++i) {
        const MethodInfo *m = findMethodInHierarchy(api, klass, getters[i], 0);
        if (!m) continue;
        Il2CppObject *exception = nullptr;
        Il2CppObject *result = api.runtime_invoke(m, obj, nullptr, &exception);
        if (exception || !result) continue;
        NSString *s = api.toNSString((Il2CppString*)result);
        if (s.length) return s;
    }
    return nil;
}

static NSString *enumLiteralName(GGDIl2CppAPI &api, Il2CppClass *enumClass, int64_t value) {
    if (!enumClass || !api.class_is_enum(enumClass) || !api.class_get_fields) return nil;
    void *iter = nullptr;
    while (FieldInfo *f = api.class_get_fields(enumClass, &iter)) {
        uint32_t flags = api.field_get_flags(f);
        if (!(flags & FIELD_ATTRIBUTE_LITERAL)) continue;
        const Il2CppType *t = api.field_get_type(f);
        uint32_t ty = t ? api.type_get_type(t) : 0;
        int64_t v = 0;
        uint8_t buf[8] = {0};
        api.field_static_get_value(f, buf);
        if (ty == IL2CPP_TYPE_I8) v = *(int64_t*)buf;
        else if (ty == IL2CPP_TYPE_U8) v = (int64_t)*(uint64_t*)buf;
        else if (ty == IL2CPP_TYPE_I2) v = *(int16_t*)buf;
        else if (ty == IL2CPP_TYPE_U2) v = *(uint16_t*)buf;
        else if (ty == IL2CPP_TYPE_I1) v = *(int8_t*)buf;
        else if (ty == IL2CPP_TYPE_U1) v = *(uint8_t*)buf;
        else if (ty == IL2CPP_TYPE_U4) v = *(uint32_t*)buf;
        else v = *(int32_t*)buf;
        if (v == value) {
            const char *n = api.field_get_name(f);
            return n ? [NSString stringWithUTF8String:n] : nil;
        }
    }
    return nil;
}

static NSString *readRole(GGDIl2CppAPI &api, Il2CppObject *obj, Il2CppClass *klass) {
    static const char *const stringNames[] = {
        "RoleName","roleName","IdentityName","identityName","FactionName","factionName",
        "CampName","campName","TeamName","teamName", nullptr
    };
    static const char *const stringGetters[] = {
        "get_RoleName","get_roleName","get_IdentityName","get_identityName",
        "get_FactionName","get_factionName","get_CampName","get_campName","get_TeamName","get_teamName", nullptr
    };
    NSString *s = readStringGetter(api, obj, klass, stringGetters);
    if (s.length) return s;
    s = readStringField(api, obj, klass, stringNames);
    if (s.length) return s;

    static const char *const valueNames[] = {
        "Role","role","CurrentRole","currentRole","RoleType","roleType","RoleId","roleId",
        "Identity","identity","Camp","camp","Faction","faction","Team","team", nullptr
    };
    FieldInfo *f = findFieldInHierarchy(api, klass, valueNames, false);
    if (!f) return nil;
    const Il2CppType *type = api.field_get_type(f);
    Il2CppClass *valueClass = type && api.type_get_class ? api.type_get_class(type) : nullptr;
    bool isEnum = valueClass && api.class_is_enum(valueClass);
    if (!isEnum) {
        uint32_t ty = type ? api.type_get_type(type) : 0;
        bool integral = ty == IL2CPP_TYPE_I1 || ty == IL2CPP_TYPE_U1 || ty == IL2CPP_TYPE_I2 || ty == IL2CPP_TYPE_U2 ||
                        ty == IL2CPP_TYPE_I4 || ty == IL2CPP_TYPE_U4 || ty == IL2CPP_TYPE_I8 || ty == IL2CPP_TYPE_U8;
        if (!integral) return nil;
    }
    int64_t raw = 0;
    if (!readManagedInt(api, obj, f, &raw)) return nil;
    if (isEnum) {
        NSString *en = enumLiteralName(api, valueClass, raw);
        if (en.length) return en;
    }
    return [NSString stringWithFormat:@"RoleId=%lld", (long long)raw];
}

static NSString *readName(GGDIl2CppAPI &api, Il2CppObject *obj, Il2CppClass *klass) {
    static const char *const getters[] = {
        "get_Nickname","get_nickname","get_NickName","get_nickName","get_PlayerName","get_playerName",
        "get_UserName","get_username","get_DisplayName","get_displayName","get_Name","get_name", nullptr
    };
    static const char *const fields[] = {
        "Nickname","nickname","NickName","nickName","PlayerName","playerName","UserName","username",
        "DisplayName","displayName","Name","name", nullptr
    };
    NSString *s = readStringGetter(api, obj, klass, getters);
    if (s.length) return s;
    return readStringField(api, obj, klass, fields);
}

static UIColor *colorForRole(NSString *role) {
    NSString *s = role.lowercaseString ?: @"";
    if ([s containsString:@"鸭"] || [s containsString:@"duck"] || [s containsString:@"killer"] || [s containsString:@"assassin"]) return UIColor.systemRedColor;
    if ([s containsString:@"鹅"] || [s containsString:@"goose"] || [s containsString:@"crew"]) return UIColor.systemGreenColor;
    if ([s containsString:@"中立"] || [s containsString:@"neutral"] || [s containsString:@"vulture"] || [s containsString:@"falcon"]) return UIColor.systemYellowColor;
    return UIColor.systemGrayColor;
}

@interface GGDRuntime : NSObject
@property(nonatomic, readonly) BOOL apiReady;
@property(nonatomic, readonly) BOOL gameReady;
@property(nonatomic, readonly) NSArray<NSDictionary*> *players;
@property(nonatomic, readonly) NSString *status;
+ (instancetype)shared;
- (void)probe;
@end

@interface GGDRuntime () {
    GGDIl2CppAPI _api;
    BOOL _resolved;
    BOOL _attached;
    BOOL _searchComplete;
    BOOL _probeEnabled;
    Il2CppClass *_ownerClass;
    FieldInfo *_playersField;
    NSString *_ownerText;
    NSMutableArray<NSDictionary*> *_players;
    NSString *_status;
    NSTimeInterval _lastProbe;
}
@end

@implementation GGDRuntime
+ (instancetype)shared { static GGDRuntime *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [GGDRuntime new]; }); return s; }
- (instancetype)init { if ((self=[super init])) { _players=[NSMutableArray array]; _status=@"安全模式：未读取游戏数据"; } return self; }
- (BOOL)apiReady { return _resolved && _attached; }
- (BOOL)gameReady { return _players.count > 0; }
- (NSArray<NSDictionary*>*)players { return [_players copy]; }
- (NSString*)status { return _status ?: @""; }

- (BOOL)profileOK {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    if (![bundle isEqualToString:@"com.seayoo.ggd"]) { _status=[NSString stringWithFormat:@"保护停止：%@", bundle]; return NO; }
    if (![version hasPrefix:@"1.1.13"]) { _status=[NSString stringWithFormat:@"保护停止：版本 %@", version]; return NO; }
    return YES;
}

- (void)probe {
    // All runtime work remains on main thread and is throttled.
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self probe]; }); return; }
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastProbe < 0.75) return;
    _lastProbe = now;
    if (![self profileOK]) return;
    _probeEnabled = YES;

    @autoreleasepool {
        if (!_resolved) {
            _resolved = _api.resolve();
            if (!_resolved) { _status=@"等待 IL2CPP Runtime"; return; }
        }
        if (!_attached) {
            if (!_api.attach()) { _status=@"IL2CPP 已发现 · 等待 Runtime 就绪"; return; }
            _attached = YES;
            _status=@"IL2CPP 已连接 · 正在定位玩家集合";
        }
        if (!_playersField) {
            [self discoverPlayerField];
            if (!_playersField) return;
        }
        [self refreshPlayers];
    }
}

- (void)discoverPlayerField {
    static const char *const preferredFields[] = {
        "players","Players","playerList","PlayerList","playersList","allPlayers",
        "playerInfos","PlayerInfos","playerInfoList","m_players","m_playerList","_players", nullptr
    };
    auto imgs = _api.images();
    if (imgs.empty()) { _status=@"IL2CPP 已连接 · 暂无程序集"; return; }

    // First pass: exact likely class names, much cheaper than a full scan.
    static const char *const likelyClasses[] = {
        "GooseGame","GameSystems","GameManager","PlayerManager","RoomManager","MeetingCtl","PlayerRoleDisplayCtl", nullptr
    };
    for (int n=0; likelyClasses[n] && !_playersField; ++n) {
        Il2CppClass *c = _api.findClassAnyNamespace(likelyClasses[n]);
        if (!c) continue;
        FieldInfo *f = findFieldInHierarchy(_api, c, preferredFields, true);
        if (!f) continue;
        const Il2CppType *t = _api.field_get_type(f);
        uint32_t ty = t ? _api.type_get_type(t) : 0;
        const char *tn = t ? _api.type_get_name(t) : nullptr;
        if (ty == IL2CPP_TYPE_SZARRAY || (tn && (ciContains(tn,"List") || ciContains(tn,"Player")))) {
            _ownerClass=c; _playersField=f;
            const char *cn=_api.class_get_name(c); const char *fn=_api.field_get_name(f);
            _ownerText=[NSString stringWithFormat:@"%s.%s", cn?cn:@"?", fn?fn:@"?"];
            _status=[NSString stringWithFormat:@"玩家集合已定位：%@", _ownerText];
            return;
        }
    }

    // Second pass: bounded metadata scan. We never inspect object memory here.
    const size_t maxClasses = 50000;
    size_t visited = 0;
    for (const Il2CppImage *img : imgs) {
        size_t count = _api.image_get_class_count(img);
        if (count > 200000) count = 200000;
        const char *imageName = _api.image_get_name(img);
        bool preferredImage = imageName && (ciContains(imageName,"Assembly-CSharp") || ciContains(imageName,"HotUpdate") || ciContains(imageName,"Game") || ciContains(imageName,"Goose"));
        if (!preferredImage && visited > 15000) continue;
        for (size_t i=0; i<count && visited<maxClasses; ++i,++visited) {
            Il2CppClass *c = _api.image_get_class(img,i);
            if (!c) continue;
            const char *cn=_api.class_get_name(c);
            bool likely = cn && (ciContains(cn,"player") || ciContains(cn,"game") || ciContains(cn,"manager") || ciContains(cn,"system") || ciContains(cn,"room") || ciContains(cn,"meeting") || ciContains(cn,"goose"));
            if (!likely) continue;
            FieldInfo *f=findFieldInHierarchy(_api,c,preferredFields,true);
            if (!f) continue;
            const Il2CppType *t=_api.field_get_type(f); const char *tn=t?_api.type_get_name(t):nullptr; uint32_t ty=t?_api.type_get_type(t):0;
            if (!(ty==IL2CPP_TYPE_SZARRAY || (tn && (ciContains(tn,"List") || ciContains(tn,"Player"))))) continue;
            _ownerClass=c; _playersField=f;
            const char *fn=_api.field_get_name(f);
            _ownerText=[NSString stringWithFormat:@"%s.%s",cn?cn:@"?",fn?fn:@"?"];
            _status=[NSString stringWithFormat:@"玩家集合已定位：%@",_ownerText];
            return;
        }
    }
    _searchComplete=YES;
    _status=@"已安全扫描运行时类型：暂未定位玩家集合";
}

- (void)refreshPlayers {
    if (!_playersField) return;
    Il2CppObject *collection = nullptr;
    _api.field_static_get_value(_playersField, &collection);
    if (!collection) { [_players removeAllObjects]; _status=[NSString stringWithFormat:@"%@ · 等待玩家对象",_ownerText?:@"玩家集合"]; return; }

    Il2CppClass *cc = _api.object_get_class(collection);
    if (!cc) { [_players removeAllObjects]; _status=@"玩家集合对象无效，已停止本轮读取"; return; }

    const MethodInfo *countMethod = findMethodInHierarchy(_api, cc, "get_Count", 0);
    const MethodInfo *itemMethod = findMethodInHierarchy(_api, cc, "get_Item", 1);
    if (!countMethod || !itemMethod) {
        // Arrays are deliberately not raw-read in v3.2. This avoids version-dependent array layout assumptions.
        [_players removeAllObjects];
        _status=[NSString stringWithFormat:@"%@ · 当前集合不是可安全调用的 List<T>",_ownerText?:@"玩家集合"];
        return;
    }

    Il2CppObject *exception=nullptr;
    Il2CppObject *boxedCount=_api.runtime_invoke(countMethod, collection, nullptr, &exception);
    if (exception || !boxedCount || !_api.object_unbox) { [_players removeAllObjects]; _status=@"读取玩家数量失败：已保护退出"; return; }
    int32_t count=*(int32_t*)_api.object_unbox(boxedCount);
    if (count<0) count=0; if (count>64) count=64;

    NSMutableArray *next=[NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int32_t i=0;i<count;++i) {
        void *arg0=&i; void *args[1]={arg0}; exception=nullptr;
        Il2CppObject *player=_api.runtime_invoke(itemMethod, collection, args, &exception);
        if (exception || !player) continue;
        Il2CppClass *pc=_api.object_get_class(player); if (!pc) continue;
        NSString *name=readName(_api,player,pc); if (!name.length) name=@"玩家";
        NSString *role=readRole(_api,player,pc); if (!role.length) role=@"未知";
        [next addObject:@{ @"name":name, @"role":role, @"color":colorForRole(role) }];
        // v3 intentionally does not touch Transform/Camera yet. That layer is version-sensitive and is enabled only after player data proves stable.
    }
    [_players removeAllObjects]; [_players addObjectsFromArray:next];
    _status=[NSString stringWithFormat:@"玩家集合=%lu · 姓名/身份读取已启用",(unsigned long)_players.count];
}
@end

@interface GGDRoleRow : UIView
@property(nonatomic,strong) UIView *dot;
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *roleLabel;
@end
@implementation GGDRoleRow
- (instancetype)init { if ((self=[super initWithFrame:CGRectMake(0,0,280,30)])) {
    self.userInteractionEnabled=NO;
    _dot=[[UIView alloc] initWithFrame:CGRectMake(3,7,16,16)]; _dot.layer.cornerRadius=8; _dot.layer.borderWidth=1; _dot.layer.borderColor=UIColor.whiteColor.CGColor; [self addSubview:_dot];
    _nameLabel=[[UILabel alloc] initWithFrame:CGRectMake(26,2,150,24)]; _nameLabel.textColor=UIColor.whiteColor; _nameLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; [self addSubview:_nameLabel];
    _roleLabel=[[UILabel alloc] initWithFrame:CGRectMake(176,2,95,24)]; _roleLabel.textColor=[UIColor colorWithWhite:0.9 alpha:1]; _roleLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightRegular]; [self addSubview:_roleLabel];
} return self; }
@end

@interface GGDOverlayView : UIView
@property(nonatomic,strong) UIButton *toggle;
@property(nonatomic,strong) UIButton *scan;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *detail;
@property(nonatomic,strong) UIStackView *stack;
@property(nonatomic,strong) NSMutableArray<GGDRoleRow*> *rows;
@property(nonatomic,strong) NSTimer *timer;
@end
@implementation GGDOverlayView
- (instancetype)initWithFrame:(CGRect)frame { if ((self=[super initWithFrame:frame])) {
    self.backgroundColor=UIColor.clearColor; self.userInteractionEnabled=YES; _rows=[NSMutableArray array];
    _toggle=[UIButton buttonWithType:UIButtonTypeSystem]; _toggle.frame=CGRectMake(16,90,122,34); _toggle.layer.cornerRadius=17; _toggle.backgroundColor=[UIColor colorWithWhite:0.05 alpha:0.9]; [_toggle setTitle:@"GGD 已加载" forState:UIControlStateNormal]; [_toggle setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; _toggle.titleLabel.font=[UIFont boldSystemFontOfSize:12]; [self addSubview:_toggle]; [_toggle addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [_toggle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(move:)]];

    _panel=[[UIView alloc] initWithFrame:CGRectMake(16,132,330,300)]; _panel.hidden=YES; _panel.layer.cornerRadius=14; _panel.backgroundColor=[UIColor colorWithWhite:0.03 alpha:0.96]; [self addSubview:_panel];
    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(14,10,210,24)]; title.text=@"GGD 身份显示"; title.textColor=UIColor.whiteColor; title.font=[UIFont boldSystemFontOfSize:15]; [_panel addSubview:title];
    _scan=[UIButton buttonWithType:UIButtonTypeSystem]; _scan.frame=CGRectMake(240,8,76,28); _scan.layer.cornerRadius=8; _scan.backgroundColor=[UIColor colorWithWhite:0.16 alpha:1]; [_scan setTitle:@"开始读取" forState:UIControlStateNormal]; [_scan setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; _scan.titleLabel.font=[UIFont boldSystemFontOfSize:10]; [_panel addSubview:_scan]; [_scan addTarget:self action:@selector(startScan) forControlEvents:UIControlEventTouchUpInside];
    _detail=[[UILabel alloc] initWithFrame:CGRectMake(14,40,302,48)]; _detail.numberOfLines=2; _detail.font=[UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular]; _detail.textColor=[UIColor colorWithWhite:0.86 alpha:1]; [_panel addSubview:_detail];
    _stack=[[UIStackView alloc] initWithFrame:CGRectMake(14,94,302,194)]; _stack.axis=UILayoutConstraintAxisVertical; _stack.spacing=1; [_panel addSubview:_stack];
    _timer=[NSTimer timerWithTimeInterval:0.6 target:self selector:@selector(refresh) userInfo:nil repeats:YES]; [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
} return self; }

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectContainsPoint(_toggle.frame, point)) return YES;
    if (!_panel.hidden && CGRectContainsPoint(_panel.frame, point)) return YES;
    return NO;
}
- (void)togglePanel { _panel.hidden=!_panel.hidden; }
- (void)startScan { [[GGDRuntime shared] probe]; [_scan setTitle:@"读取中" forState:UIControlStateNormal]; }
- (void)move:(UIPanGestureRecognizer*)g { CGPoint d=[g translationInView:self]; CGRect r=_toggle.frame; r.origin.x=MAX(0,MIN(self.bounds.size.width-r.size.width,r.origin.x+d.x)); r.origin.y=MAX(40,MIN(self.bounds.size.height-r.size.height,r.origin.y+d.y)); _toggle.frame=r; _panel.frame=CGRectMake(r.origin.x,r.origin.y+r.size.height+8,_panel.frame.size.width,_panel.frame.size.height); [g setTranslation:CGPointMake(0,0) inView:self]; }
- (void)refresh {
    GGDRuntime *rt=GGDRuntime.shared;
    _toggle.alpha=1.0;
    BOOL ready=rt.apiReady;
    [_toggle setTitle:(ready?@"GGD 已连接":@"GGD 已加载") forState:UIControlStateNormal];
    NSArray *ps=rt.players;
    _detail.text=[NSString stringWithFormat:@"Runtime: %@\n玩家数: %lu\n%@", ready?@"OK":@"未启动", (unsigned long)ps.count, rt.status];
    while (_rows.count < ps.count) { GGDRoleRow *row=[GGDRoleRow new]; [_stack addArrangedSubview:row]; [_rows addObject:row]; }
    for (NSUInteger i=0;i<_rows.count;++i) {
        GGDRoleRow *row=_rows[i]; row.hidden=i>=ps.count; if (i<ps.count) { NSDictionary *p=ps[i]; row.dot.backgroundColor=p[@"color"]; row.nameLabel.text=p[@"name"]; row.roleLabel.text=p[@"role"]; }
    }
}
- (void)dealloc { [_timer invalidate]; }
@end

static GGDOverlayView *gOverlay;
static UIWindow *findGameWindow(void) {
    if (@available(iOS 13.0,*)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws=(UIWindowScene*)scene; if (ws.activationState==UISceneActivationStateUnattached) continue;
            for (UIWindow *w in ws.windows) if (!w.hidden && w.alpha>0.01 && w.rootViewController) return w;
        }
    }
    return nil;
}
static void install(void) {
    if (gOverlay) return;
    UIWindow *w=findGameWindow();
    if (!w) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ install(); }); return; }
    gOverlay=[[GGDOverlayView alloc] initWithFrame:w.bounds]; gOverlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [w addSubview:gOverlay];
}
__attribute__((constructor)) static void ctor(void) {
    // Absolutely no IL2CPP interaction here. This is intentionally boring.
    dispatch_async(dispatch_get_main_queue(),^{ dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ install(); }); });
}
