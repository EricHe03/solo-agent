package dtx

import (
	"maps"
	"reflect"
	"slices"
	"strconv"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"

	"howett.net/plist"
)

type Object struct {
	ClassName       string
	Fields          map[string]any
	PrimitiveFields []string
}

func MarshalArchive(value any) ([]byte, error) {
	e := archiveEncoder{objects: []any{"$null"}, classes: make(map[string]plist.UID)}
	root, err := e.encode(reflect.ValueOf(value))
	if err != nil {
		return nil, err
	}
	data, err := plist.Marshal(map[string]any{
		"$archiver": "NSKeyedArchiver", "$version": uint64(100000),
		"$objects": e.objects, "$top": map[string]any{"root": root},
	}, plist.BinaryFormat)
	if err != nil {
		return nil, E.Cause(err, "dtx: encode archive")
	}
	return data, nil
}

type archiveEncoder struct {
	objects []any
	classes map[string]plist.UID
}

func (e *archiveEncoder) append(value any) plist.UID {
	uid := plist.UID(len(e.objects))
	e.objects = append(e.objects, value)
	return uid
}

func (e *archiveEncoder) class(name string) plist.UID {
	if uid, ok := e.classes[name]; ok {
		return uid
	}
	uid := e.append(map[string]any{"$classname": name, "$classes": []string{name, "NSObject"}})
	e.classes[name] = uid
	return uid
}

func (e *archiveEncoder) encode(value reflect.Value) (plist.UID, error) {
	if !value.IsValid() {
		return 0, nil
	}
	if value.Kind() == reflect.Interface {
		if value.IsNil() {
			return 0, nil
		}
		return e.encode(value.Elem())
	}
	if (value.Kind() == reflect.Map || value.Kind() == reflect.Slice || value.Kind() == reflect.Pointer) && value.IsNil() {
		return 0, nil
	}
	if value.CanInterface() {
		switch object := value.Interface().(type) {
		case Object:
			return e.object(object)
		case *Object:
			return e.object(*object)
		}
	}
	if primitive, ok := archivePrimitive(value); ok {
		return e.append(primitive), nil
	}
	return e.collection(value)
}

func archivePrimitive(value reflect.Value) (any, bool) {
	switch value.Kind() {
	case reflect.String:
		return value.String(), true
	case reflect.Bool:
		return value.Bool(), true
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return value.Int(), true
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return value.Uint(), true
	case reflect.Float32, reflect.Float64:
		return value.Float(), true
	case reflect.Slice:
		if value.Type().Elem().Kind() == reflect.Uint8 {
			return value.Bytes(), true
		}
	}
	return nil, false
}

func (e *archiveEncoder) object(value Object) (plist.UID, error) {
	for _, name := range value.PrimitiveFields {
		if _, exists := value.Fields[name]; !exists {
			return 0, E.New("dtx: missing primitive archive field ", strconv.Quote(name))
		}
	}
	object := make(map[string]any, len(value.Fields)+1)
	uid := e.append(object)
	object["$class"] = e.class(value.ClassName)
	for _, name := range slices.Sorted(maps.Keys(value.Fields)) {
		field := reflect.ValueOf(value.Fields[name])
		if slices.Contains(value.PrimitiveFields, name) {
			var ok bool
			object[name], ok = archivePrimitive(field)
			if !ok {
				return 0, E.New("dtx: unsupported primitive archive field ", strconv.Quote(name))
			}
		} else {
			var err error
			object[name], err = e.encode(field)
			if err != nil {
				return 0, err
			}
		}
	}
	return uid, nil
}

func (e *archiveEncoder) collection(value reflect.Value) (plist.UID, error) {
	if value.Kind() != reflect.Map && value.Kind() != reflect.Slice && value.Kind() != reflect.Array {
		return 0, E.New("dtx: unsupported archive value ", value.Type())
	}
	if value.Kind() == reflect.Map && value.Type().Key().Kind() != reflect.String {
		return 0, E.New("dtx: archive dictionary keys must be strings")
	}
	object := make(map[string]any)
	uid := e.append(object)
	className := "NSArray"
	if value.Kind() == reflect.Map {
		className = "NSDictionary"
	}
	object["$class"] = e.class(className)
	values := make([]plist.UID, value.Len())
	var err error
	if value.Kind() == reflect.Map {
		keys := value.MapKeys()
		common.SortBy(keys, reflect.Value.String)
		keyUIDs := make([]plist.UID, len(keys))
		for i, key := range keys {
			keyUIDs[i], err = e.encode(key)
			if err != nil {
				return 0, err
			}
			values[i], err = e.encode(value.MapIndex(key))
			if err != nil {
				return 0, err
			}
		}
		object["NS.keys"] = keyUIDs
	} else {
		for i := range values {
			values[i], err = e.encode(value.Index(i))
			if err != nil {
				return 0, err
			}
		}
	}
	object["NS.objects"] = values
	return uid, nil
}

func UnmarshalArchive(data []byte) (any, error) {
	plistValue, err := decodeBinaryPlist(data)
	if err != nil {
		return nil, err
	}
	envelope, ok := plistValue.(map[string]any)
	if !ok || envelope["$archiver"] != "NSKeyedArchiver" || envelope["$version"] != uint64(100000) {
		return nil, E.New("dtx: invalid keyed archive envelope")
	}
	objects, ok := envelope["$objects"].([]any)
	if !ok || len(objects) == 0 {
		return nil, E.New("dtx: invalid keyed archive object table")
	}
	if null, ok := objects[0].(string); !ok || null != "$null" {
		return nil, E.New("dtx: invalid keyed archive null object")
	}
	top, ok := envelope["$top"].(map[string]any)
	if !ok {
		return nil, E.New("dtx: invalid keyed archive root")
	}
	root, ok := top["root"].(plist.UID)
	if !ok {
		return nil, E.New("dtx: missing keyed archive root reference")
	}
	d := archiveDecoder{objects: objects, active: make(map[plist.UID]bool), cache: make(map[plist.UID]any)}
	return d.resolve(root)
}

type archiveDecoder struct {
	objects []any
	active  map[plist.UID]bool
	cache   map[plist.UID]any
}

func (d *archiveDecoder) resolve(value any) (any, error) {
	switch value := value.(type) {
	case plist.UID:
		if uint64(value) >= uint64(len(d.objects)) {
			return nil, E.New("dtx: archive reference ", uint64(value), " is out of bounds")
		}
		if value == 0 {
			return nil, nil
		}
		if d.active[value] {
			return nil, E.New("dtx: cyclic archive reference ", uint64(value))
		}
		if result, ok := d.cache[value]; ok {
			return result, nil
		}
		d.active[value] = true
		result, err := d.resolve(d.objects[value])
		delete(d.active, value)
		if err == nil {
			d.cache[value] = result
		}
		return result, err
	case []any:
		result := make([]any, len(value))
		for i, item := range value {
			var err error
			result[i], err = d.resolve(item)
			if err != nil {
				return nil, err
			}
		}
		return result, nil
	case map[string]any:
		return d.object(value)
	default:
		return value, nil
	}
}

func (d *archiveDecoder) object(object map[string]any) (any, error) {
	var name string
	if class, exists := object["$class"]; exists {
		uid, ok := class.(plist.UID)
		if !ok || uid == 0 || uint64(uid) >= uint64(len(d.objects)) {
			return nil, E.New("dtx: invalid archive class reference")
		}
		metadata, ok := d.objects[uid].(map[string]any)
		if !ok {
			return nil, E.New("dtx: invalid archive class metadata")
		}
		name, ok = metadata["$classname"].(string)
		if !ok || name == "" {
			return nil, E.New("dtx: missing archive class name")
		}
	}
	switch name {
	case "NSNull":
		return nil, nil
	case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSOrderedSet", "NSMutableOrderedSet":
		values, ok := object["NS.objects"].([]any)
		if !ok {
			return nil, E.New("dtx: invalid ", name, " elements")
		}
		return d.resolve(values)
	case "NSDictionary", "NSMutableDictionary":
		keys, keysOK := object["NS.keys"].([]any)
		values, valuesOK := object["NS.objects"].([]any)
		if !keysOK || !valuesOK || len(keys) != len(values) {
			return nil, E.New("dtx: invalid ", name, " entries")
		}
		result := make(map[any]any, len(keys))
		allStrings := true
		for i, key := range keys {
			decoded, err := d.resolve(key)
			if err != nil {
				return nil, err
			}
			switch decoded.(type) {
			case string:
			case int64, uint64:
				allStrings = false
			default:
				return nil, E.New("dtx: archive dictionary key must be a string or integer, got ", reflect.TypeOf(decoded))
			}
			if _, duplicate := result[decoded]; duplicate {
				return nil, E.New("dtx: duplicate archive dictionary key ", decoded)
			}
			result[decoded], err = d.resolve(values[i])
			if err != nil {
				return nil, err
			}
		}
		if allStrings {
			strings := make(map[string]any, len(result))
			for key, value := range result {
				strings[key.(string)] = value
			}
			return strings, nil
		}
		return result, nil
	case "NSString", "NSMutableString", "NSData", "NSMutableData", "NSNumber":
		var fields []string
		switch name {
		case "NSData", "NSMutableData":
			fields = []string{"NS.data"}
		case "NSNumber":
			fields = []string{"NS.boolval", "NS.intval", "NS.floatval", "NS.doubleval"}
		default:
			fields = []string{"NS.string"}
		}
		for _, field := range fields {
			if value, ok := object[field]; ok {
				return d.resolve(value)
			}
		}
		return nil, E.New("dtx: missing ", name, " value")
	default:
		result := make(map[string]any, len(object))
		for key, value := range object {
			if key == "$class" {
				result[key] = name
				continue
			}
			var err error
			result[key], err = d.resolve(value)
			if err != nil {
				return nil, err
			}
		}
		return result, nil
	}
}
