#if defined(GB_SYSTEM_WINDOWS)
	#pragma warning(push)
	#pragma warning(disable: 4200)
	#pragma warning(disable: 4201)
	#define restrict gb_restrict
#endif

#include "tilde/tb.h"

#if defined(GB_SYSTEM_WINDOWS)
	#pragma warning(pop)
#endif

#define CG_STARTUP_RUNTIME_PROC_NAME   "__$startup_runtime"
#define CG_CLEANUP_RUNTIME_PROC_NAME   "__$cleanup_runtime"
#define CG_STARTUP_TYPE_INFO_PROC_NAME "__$startup_type_info"
#define CG_TYPE_INFO_DATA_NAME       "__$type_info_data"
#define CG_TYPE_INFO_TYPES_NAME      "__$type_info_types_data"
#define CG_TYPE_INFO_NAMES_NAME      "__$type_info_names_data"
#define CG_TYPE_INFO_OFFSETS_NAME    "__$type_info_offsets_data"
#define CG_TYPE_INFO_USINGS_NAME     "__$type_info_usings_data"
#define CG_TYPE_INFO_TAGS_NAME       "__$type_info_tags_data"

struct cgModule;


enum cgValueKind : u32 {
	cgValue_Value,
	cgValue_Addr,
	cgValue_Symbol,
};

struct cgValue {
	cgValueKind kind;
	Type *      type;
	union {
		TB_Symbol *symbol;
		TB_Node *  node;
	};
};

enum cgAddrKind {
	cgAddr_Default,
	cgAddr_Map,
	cgAddr_Context,
	cgAddr_SoaVariable,

	cgAddr_RelativePointer,
	cgAddr_RelativeSlice,

	cgAddr_Swizzle,
	cgAddr_SwizzleLarge,
};

struct cgAddr {
	cgAddrKind kind;
	cgValue addr;
	union {
		struct {
			cgValue key;
			Type *type;
			Type *result;
		} map;
		struct {
			Selection sel;
		} ctx;
		struct {
			cgValue index;
			Ast *index_expr;
		} soa;
		struct {
			cgValue index;
			Ast *node;
		} index_set;
		struct {
			bool deref;
		} relative;
		struct {
			Type *type;
			u8 count;      // 2, 3, or 4 components
			u8 indices[4];
		} swizzle;
		struct {
			Type *type;
			Slice<i32> indices;
		} swizzle_large;
	};
};


struct cgProcedure {
	u32 flags;
	u16 state_flags;

	cgProcedure *parent;
	Array<cgProcedure *> children;

	TB_Function *func;
	TB_Symbol *symbol;

	Entity *  entity;
	cgModule *module;
	String    name;
	Type *    type;
	Ast *     type_expr;
	Ast *     body;
	u64       tags;
	ProcInlining inlining;
	bool         is_foreign;
	bool         is_export;
	bool         is_entry_point;
	bool         is_startup;

	cgValue value;

};


struct cgModule {
	TB_Module *  mod;
	Checker *    checker;
	CheckerInfo *info;

	RwMutex values_mutex;
	PtrMap<Entity *, cgValue> values;
	StringMap<cgValue> members;

	StringMap<cgProcedure *> procedures;
	PtrMap<TB_Function *, Entity *> procedure_values;
	Array<cgProcedure *> procedures_to_generate;

	std::atomic<u32> nested_type_name_guid;
};

#ifndef ABI_PKG_NAME_SEPARATOR
#define ABI_PKG_NAME_SEPARATOR "."
#endif

gb_global Entity *cg_global_type_info_data_entity   = {};
gb_global cgAddr cg_global_type_info_member_types   = {};
gb_global cgAddr cg_global_type_info_member_names   = {};
gb_global cgAddr cg_global_type_info_member_offsets = {};
gb_global cgAddr cg_global_type_info_member_usings  = {};
gb_global cgAddr cg_global_type_info_member_tags    = {};

gb_global isize cg_global_type_info_data_index           = 0;
gb_global isize cg_global_type_info_member_types_index   = 0;
gb_global isize cg_global_type_info_member_names_index   = 0;
gb_global isize cg_global_type_info_member_offsets_index = 0;
gb_global isize cg_global_type_info_member_usings_index  = 0;
gb_global isize cg_global_type_info_member_tags_index    = 0;

gb_internal cgValue cg_value(TB_Global *  g,    Type *type);
gb_internal cgValue cg_value(TB_External *e,    Type *type);
gb_internal cgValue cg_value(TB_Function *f,    Type *type);
gb_internal cgValue cg_value(TB_Symbol *  s,    Type *type);
gb_internal cgValue cg_value(TB_Node *    node, Type *type);

gb_internal cgAddr cg_addr(cgValue const &value);

