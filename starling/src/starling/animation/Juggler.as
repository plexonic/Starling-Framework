// =================================================================================================
//
//	Starling Framework
//	Copyright Gamua GmbH. All Rights Reserved.
//
//	This program is free software. You can redistribute and/or modify it
//	in accordance with the terms of the accompanying license agreement.
//
// =================================================================================================

package starling.animation {
import flash.utils.Dictionary;

import starling.events.Event;
import starling.events.EventDispatcher;

public class Juggler implements IAnimatable {
    public static const JUGGLING_STOPPED:String = "jugglingStopped";

    private var _objects:Vector.<IAnimatable>;
    private var _objectIDs:Dictionary;
    private var _elapsedTime:Number;
    private var _timeScale:Number;

    private static var sCurrentObjectID:uint;
    private var _eventDispatcher:EventDispatcher;
    private var _name:String;

    /** Create an empty juggler. */
    public function Juggler(name:String = null) {
        _elapsedTime = 0;
        _timeScale = 1.0;
        _objects = new <IAnimatable>[];
        _objectIDs = new Dictionary(true);
        _eventDispatcher = new EventDispatcher();
        _name = name;
    }

    /** Adds an object to the juggler.
     *
     *  @return Unique numeric identifier for the animation. This identifier may be used
     *          to remove the object via <code>removeByID()</code>.
     */
    public function add(object:IAnimatable):uint {
        return addWithID(object, getNextID());
    }

    private function addWithID(object:IAnimatable, objectID:uint):uint {
        if (object && !(object in _objectIDs)) {
            _objects[_objects.length] = object;
            _objectIDs[object] = objectID;

            return objectID;
        }
        else return 0;
    }

    /** Determines if an object has been added to the juggler. */
    public function contains(object:IAnimatable):Boolean {
        return object in _objectIDs;
    }

    /** Removes an object from the juggler.
     *
     *  @return The (now meaningless) unique numeric identifier for the animation, or zero
     *          if the object was not found.
     */
    public function remove(object:IAnimatable):uint {
        var objectID:uint = 0;

        if (object && object in _objectIDs) {
            var index:int = _objects.indexOf(object);
            _objects[index] = null;

            objectID = _objectIDs[object];
            delete _objectIDs[object];
        }

        return objectID;
    }

    /** Removes an object from the juggler, identified by the unique numeric identifier you
     *  received when adding it.
     *
     *  <p>It's not uncommon that an animatable object is added to a juggler repeatedly,
     *  e.g. when using an object-pool. Thus, when using the <code>remove</code> method,
     *  you might accidentally remove an object that has changed its context. By using
     *  <code>removeByID</code> instead, you can be sure to avoid that, since the objectID
     *  will always be unique.</p>
     *
     *  @return if successful, the passed objectID; if the object was not found, zero.
     */
    public function removeByID(objectID:uint):uint {
        for (var i:int = _objects.length - 1; i >= 0; --i) {
            var object:IAnimatable = _objects[i];

            if (_objectIDs[object] == objectID) {
                remove(object);
                return objectID;
            }
        }

        return 0;
    }


    /** Removes all objects at once. */
    public function purge():void {
        // the object vector is not purged right away, because if this method is called
        // from an 'advanceTime' call, this would make the loop crash. Instead, the
        // vector is filled with 'null' values. They will be cleaned up on the next call
        // to 'advanceTime'.

        for (var i:int = _objects.length - 1; i >= 0; --i) {
            var object:IAnimatable = _objects[i];
            _objects[i] = null;
            delete _objectIDs[object];
        }
    }

    /** Advances all objects by a certain time (in seconds). */
    public function advanceTime(time:Number):void {
        var numObjects:int = _objects.length;
        var currentIndex:int = 0;
        var i:int;

        time *= _timeScale;
        if (numObjects == 0 || time == 0) return;
        _elapsedTime += time;

        // there is a high probability that the "advanceTime" function modifies the list
        // of animatables. we must not process new objects right now (they will be processed
        // in the next frame), and we need to clean up any empty slots in the list.

        for (i = 0; i < numObjects; ++i) {
            var object:IAnimatable = _objects[i];
            if (object) {
                // shift objects into empty slots along the way
                if (currentIndex != i) {
                    _objects[currentIndex] = object;
                    _objects[i] = null;
                }

                object.advanceTime(time);
                ++currentIndex;
            }
        }

        if (currentIndex != i) {
            numObjects = _objects.length; // count might have changed!

            while (i < numObjects)
                _objects[int(currentIndex++)] = _objects[int(i++)];

            _objects.length = currentIndex;
        }

        if (!isJuggling) {
            dispatchEventWith(JUGGLING_STOPPED);
        }
    }

    public function get isJuggling():Boolean {
        return objects.length > 0;
    }

    private static function getNextID():uint {
        return ++sCurrentObjectID;
    }

    /** The total life time of the juggler (in seconds). */
    public function get elapsedTime():Number {
        return _elapsedTime;
    }

    /** The scale at which the time is passing. This can be used for slow motion or time laps
     *  effects. Values below '1' will make all animations run slower, values above '1' faster.
     *  @default 1.0 */
    public function get timeScale():Number {
        return _timeScale;
    }

    public function set timeScale(value:Number):void {
        _timeScale = value;
    }

    /** The actual vector that contains all objects that are currently being animated. */
    protected function get objects():Vector.<IAnimatable> {
        return _objects;
    }

    public function addEventListener(type:String, listener:Function):void {
        _eventDispatcher.addEventListener(type, listener);
    }

    public function removeEventListener(type:String, listener:Function):void {
        _eventDispatcher.removeEventListener(type, listener);
    }

    public function removeEventListeners(type:String = null):void {
        _eventDispatcher.removeEventListeners(type);
    }

    public function dispatchEvent(event:Event):void {
        _eventDispatcher.dispatchEvent(event);
    }

    public function dispatchEventWith(type:String, bubbles:Boolean = false, data:Object = null):void {
        _eventDispatcher.dispatchEventWith(type, bubbles, data);
    }

    public function hasEventListener(type:String, listener:Function = null):Boolean {
        return _eventDispatcher.hasEventListener(type);
    }
}
}
