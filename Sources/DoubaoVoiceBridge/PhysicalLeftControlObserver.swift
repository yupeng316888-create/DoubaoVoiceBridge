import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Observes only the left Control HID usage on physical keyboards. Quartz
/// synthetic modifier events sent to the input method never enter this stream.
final class PhysicalLeftControlObserver {
    private let onChange: (Bool) -> Void
    private var manager: IOHIDManager?
    private var pressedDevices: Set<ObjectIdentifier> = []

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread)
        if manager != nil { return true }
        // IOHIDManagerOpen may prompt on an undecided grant. Keep the existing
        // Quartz input path available until the app already has listen access.
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return false }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey: kHIDUsage_KeyboardLeftControl
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad,
                  IOHIDElementGetUsage(element) == kHIDUsage_KeyboardLeftControl,
                  PhysicalLeftControlObserver.isPhysicalKeyboard(device) else { return }
            let observer = Unmanaged<PhysicalLeftControlObserver>.fromOpaque(context).takeUnretainedValue()
            observer.update(device: device, down: IOHIDValueGetIntegerValue(value) != 0)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let observer = Unmanaged<PhysicalLeftControlObserver>.fromOpaque(context).takeUnretainedValue()
            observer.update(device: device, down: false)
        }, context)
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard let manager else { return }
        self.manager = nil
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, 0)
        pressedDevices.removeAll()
    }

    deinit { stop() }

    static func isPhysicalKeyboard(_ device: IOHIDDevice) -> Bool {
        guard let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String else {
            return false
        }
        switch transport {
        case "USB", "Bluetooth", "Bluetooth Low Energy", "BluetoothLowEnergy", "SPI", "I2C", "ADB", "AID":
            return true
        default:
            return false
        }
    }

    private func update(device: IOHIDDevice, down: Bool) {
        let wasDown = !pressedDevices.isEmpty
        let id = ObjectIdentifier(device)
        if down { pressedDevices.insert(id) } else { pressedDevices.remove(id) }
        let isDown = !pressedDevices.isEmpty
        if isDown != wasDown { onChange(isDown) }
    }
}
