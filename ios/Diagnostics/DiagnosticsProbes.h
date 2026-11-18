#import <Foundation/Foundation.h>
#include <atomic>

// Runs on one diagnostic worker. The host has already registered/retained the
// layer on the main thread. No UIKit, GPU commands, device creation, or engine.
NSString *BO1RunDiagnosticProbes(const std::atomic_bool *cancelled);
