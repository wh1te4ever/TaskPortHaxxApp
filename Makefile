GO_EASY_ON_ME = 1
DEBUG = 0
FINALPACKAGE = 1

TARGET := iphone:clang:16.5:14.5
INSTALL_TARGET_PROCESSES = TaskPortHaxxApp
ARCHS = arm64 arm64e
PACKAGE_FORMAT = ipa

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TaskPortHaxxApp

TaskPortHaxxApp_FILES = \
	TaskPortHaxxApp/AppDelegate.m \
	TaskPortHaxxApp/SceneDelegate.m \
	TaskPortHaxxApp/ViewController.m \
	TaskPortHaxxApp/main.m \
	TaskPortHaxxApp/exception_handler.m \
	TaskPortHaxxApp/psychicpaper_proxy.m \
	TaskPortHaxxApp/mach_excServer.c
TaskPortHaxxApp_FRAMEWORKS = UIKit CoreGraphics
TaskPortHaxxApp_CFLAGS = -fobjc-arc
TaskPortHaxxApp_CODESIGN_FLAGS = -S./TaskPortHaxxApp/TaskPortHaxxApp.ent

include $(THEOS_MAKE_PATH)/application.mk

#SUBPROJECTS += opainject
#include $(THEOS_MAKE_PATH)/aggregate.mk
