//
//  JavaJNI.swift
//  SwiftJava
//
//  Created by John Holdsworth on 13/07/2016.
//  Copyright (c) 2016 John Holdsworth. All rights reserved.
//

import CJavaVM
import Foundation

@_silgen_name("JNI_OnLoad")
func JNI_OnLoad( jvm: UnsafeMutablePointer<JavaVM?>, ptr: UnsafeRawPointer ) -> jint {
    JNI.jvm = jvm
    let env = JNI.GetEnv()
    JNI.envCache[pthread_self()] = env
    JNI.api = env!.pointee!.pointee
    return jint(JNI_VERSION_1_6)
}

public func JNI_DetachCurrentThread() {
    _ = JNI.jvm?.pointee?.pointee.DetachCurrentThread( JNI.jvm )
    JNI.envCache[pthread_self()] = nil
}

public let JNI = JavaJNI()

open class JavaJNI {

    open var jvm: UnsafeMutablePointer<JavaVM?>?
    open var api: JNINativeInterface_!

    open var envCache = [pthread_t:UnsafeMutablePointer<JNIEnv?>?]()
    private let envLock = NSLock()

    open var env: UnsafeMutablePointer<JNIEnv?>? {
        let currentThread = pthread_self()
        if let env = envCache[currentThread] {
            return env
        }
        let env = AttachCurrentThread()
        envLock.lock()
        envCache[currentThread] = env
        envLock.unlock()
        return env
    }

    open func report( _ msg: String, _ file: StaticString = #file, _ line: Int = #line ) {
        NSLog( "\(msg) - at \(file):\(line)" )
        if api.ExceptionCheck( env ) != 0 {
            api.ExceptionDescribe( env )
        }
    }

    open func initJVM( options: [String]? = nil, _ file: StaticString = #file, _ line: Int = #line ) -> Bool {
        #if os(Android)
        return true
        #else
        if jvm != nil {
            report( "JVM can only be initialised once", file, line )
            return true
        }

        var options = options
        if options == nil {
            var classpath = String( cString: getenv("HOME") )+"/.genie.jar"
            if let CLASSPATH = getenv("CLASSPATH") {
                classpath += ":"+String( cString: CLASSPATH )
            }
            options = ["-Djava.class.path="+classpath,
                       // add to bootclasspath as threads not started using Thread class
                       // will not have the correct classloader and be missing classpath
                       "-Xbootclasspath/a:"+classpath]
        }

        var vmOptions = [JavaVMOption]( repeating: JavaVMOption(), count: options?.count ?? 1 )

        return withUnsafeMutablePointer(to: &vmOptions[0]) {
            (vmOptionsPtr) in
            var vmArgs = JavaVMInitArgs()
            vmArgs.version = jint(JNI_VERSION_1_6)
            vmArgs.nOptions = jint(options?.count ?? 0)
            vmArgs.options = vmOptionsPtr

            if let options = options {
                for i in 0..<options.count {
                    options[i].withCString {
                        (cString) in
                        vmOptions[i].optionString = strdup( cString )
                    }
                }
            }

            var tenv: UnsafeMutablePointer<JNIEnv?>?
            if withPointerToRawPointer(to: &tenv, {
                JNI_CreateJavaVM( &self.jvm, $0, &vmArgs ) != jint(JNI_OK)
            } ) {
                self.report( "JNI_CreateJavaVM failed", file, line )
                return false
            }

            self.envCache[pthread_self()] = tenv
            self.api = self.env!.pointee!.pointee
            return true
        }
        #endif
    }

    private func withPointerToRawPointer<T, Result>(to arg: inout T, _ body: @escaping (UnsafeMutablePointer<UnsafeMutableRawPointer?>) throws -> Result) rethrows -> Result {
        return try withUnsafePointer(to: &arg) {
            try body( unsafeBitCast( $0, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self ) )
        }
    }
    
    open func GetEnv() -> UnsafeMutablePointer<JNIEnv?>? {
        var tenv: UnsafeMutablePointer<JNIEnv?>?
        if withPointerToRawPointer(to: &tenv, {
            JNI.jvm?.pointee?.pointee.GetEnv(JNI.jvm, $0, jint(JNI_VERSION_1_6) ) != jint(JNI_OK)
        } ) {
            report( "Unable to get initial JNIEnv" )
        }
        return tenv
    }

    open func AttachCurrentThread() -> UnsafeMutablePointer<JNIEnv?>? {
        var tenv: UnsafeMutablePointer<JNIEnv?>?
        if withPointerToRawPointer(to: &tenv, {
            self.jvm?.pointee?.pointee.AttachCurrentThread( self.jvm, $0, nil ) != jint(JNI_OK)
        } ) {
            report( "Could not attach to background jvm" )
        }
        return tenv
    }

    private func autoInit() {
        envLock.lock()
        if envCache.isEmpty && !initJVM() {
            report( "Auto JVM init failed" )
        }
        envLock.unlock()
    }

    open func background( closure: @escaping () -> () ) {
        autoInit()
        #if !os(Linux) && !os(Android)
            DispatchQueue.global(qos: .default).async {
                closure()
            }
        #else
            closure()
        #endif
    }

    public func run() {
        #if !os(Linux) && !os(Android)
            RunLoop.main.run(until: Date.distantFuture)
        #else
            sleep(1_000_000)
        #endif
    }

    open func FindClass( _ name: UnsafePointer<Int8>, _ file: StaticString = #file, _ line: Int = #line ) -> jclass? {
        autoInit()
        ExceptionReset()
        let clazz = api.FindClass( env, name )
        if clazz == nil {
            report( "Could not find class \(String( cString: name ))", file, line )
            if strncmp( name, "org/genie/", 10 ) == 0 {
                report( "Looking for a genie proxy class required for event listeners and Runnable's to work.\n" +
                    "Have you copied genie.jar to ~/.genie.jar and/or set the CLASSPATH environment variable?\n" )
            }
        }
        return clazz
    }

    open func CachedFindClass( _ name: UnsafePointer<Int8>, _ classCache: UnsafeMutablePointer<jclass?>,
                               _ file: StaticString = #file, _ line: Int = #line ) {
        if classCache.pointee == nil, let clazz = FindClass( name, file, line ) {
            classCache.pointee = api.NewGlobalRef( JNI.env, clazz )
        }
    }

    open func GetObjectClass( _ object: jobject?, _ locals: UnsafeMutablePointer<[jobject]>?,
                              _ file: StaticString = #file, _ line: Int = #line ) -> jclass? {
        ExceptionReset()
        if object == nil {
            report( "GetObjectClass with nil object", file, line )
        }
        let clazz = api.GetObjectClass( env, object )
        if clazz == nil {
            report( "GetObjectClass returns nil class", file, line )
        }
        else {
            locals?.pointee.append( clazz! )
        }
        return clazz
    }

    private static var java_lang_ObjectClass: jclass?

    open func NewObjectArray( _ count: Int, _ file: StaticString = #file, _ line: Int = #line  ) -> jobject? {
        CachedFindClass( "java/lang/Object", &JavaJNI.java_lang_ObjectClass, file, line )
        let array = api.NewObjectArray( env, jsize(count), JavaJNI.java_lang_ObjectClass, nil )
        if array == nil {
            report( "Could not create array", file, line )
        }
        return array
    }

    open func DeleteLocalRef( _ local: jobject? ) {
        if local != nil {
            api.DeleteLocalRef( env, local )
        }
    }

    private var thrownCache = [pthread_t:jthrowable]()
    private let thrownLock = NSLock()

    open func check<T>( _ result: T, _ locals: UnsafePointer<[jobject]>?, _ file: StaticString = #file, _ line: Int = #line ) -> T {
        if let locals = locals {
            for local in locals.pointee {
                DeleteLocalRef( local )
            }
        }
        if api.ExceptionCheck( env ) != 0, let throwable = api.ExceptionOccurred( env ) {
            report( "Exception occured", file, line )
            thrownLock.lock()
            thrownCache[pthread_self()] = throwable
            thrownLock.unlock()
            api.ExceptionClear( env )
        }
        return result
    }

    open func ExceptionCheck() -> jthrowable? {
        let currentThread = pthread_self()
        if let throwable = thrownCache[currentThread] {
            thrownLock.lock()
            thrownCache.removeValue(forKey: currentThread)
            thrownLock.unlock()
            return throwable
        }
        return nil
    }

    open func ExceptionReset() {
        if let _ = ExceptionCheck() {
            report( "Left over exception" )
        }
    }

}
