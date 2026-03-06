import ctypes
import os

objc = ctypes.cdll.LoadLibrary('/usr/lib/libobjc.A.dylib')
objc.objc_copyClassList.restype = ctypes.POINTER(ctypes.c_void_p)
objc.class_getName.restype = ctypes.c_char_p

# Load Virtualization explicitly
ctypes.cdll.LoadLibrary('/System/Library/Frameworks/Virtualization.framework/Virtualization')

num_classes = ctypes.c_uint(0)
classes = objc.objc_copyClassList(ctypes.byref(num_classes))
print(f"Total classes: {num_classes.value}")

for i in range(num_classes.value):
    try:
        name_ptr = objc.class_getName(classes[i])
        if name_ptr:
            name = name_ptr.decode('utf-8', errors='ignore')
            if name.startswith('VZ') and ('Network' in name or 'MAC' in name):
                print(name)
    except Exception as e:
        pass
