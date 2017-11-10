// =================================================================================================
//
//  Starling Framework
//  Copyright Gamua GmbH. All Rights Reserved.
//
//	This program is free software. You can redistribute and/or modify it
//	in accordance with the terms of the accompanying license agreement.
//
// =================================================================================================

package starling.rendering {
import flash.display3D.Context3D;
import flash.display3D.VertexBuffer3D;
import flash.errors.IllegalOperationError;
import flash.geom.Matrix;
import flash.geom.Matrix3D;
import flash.geom.Point;
import flash.geom.Rectangle;
import flash.geom.Vector3D;
import flash.utils.Endian;

import avm2.intrinsics.memory.lf32;
import avm2.intrinsics.memory.li32;
import avm2.intrinsics.memory.li8;
import avm2.intrinsics.memory.sf32;
import avm2.intrinsics.memory.si32;
import avm2.intrinsics.memory.si8;

import plexonic.bugtracker.BugTrackerDataProvider;

import plexonic.memory.FastByteArray;

import starling.core.Starling;
import starling.errors.MissingContextError;
import starling.styles.MeshStyle;
import starling.utils.MathUtil;
import starling.utils.MatrixUtil;
import starling.utils.StringUtil;

/** The VertexData class manages a raw list of vertex information, allowing direct upload
 *  to Stage3D vertex buffers. <em>You only have to work with this class if you're writing
 *  your own rendering code (e.g. if you create custom display objects).</em>
 *
 *  <p>To render objects with Stage3D, you have to organize vertices and indices in so-called
 *  vertex- and index-buffers. Vertex buffers store the coordinates of the vertices that make
 *  up an object; index buffers reference those vertices to determine which vertices spawn
 *  up triangles. Those buffers reside in graphics memory and can be accessed very
 *  efficiently by the GPU.</p>
 *
 *  <p>Before you can move data into the buffers, you have to set it up in conventional
 *  memory — that is, in a Vector or a ByteArray. Since it's quite cumbersome to manually
 *  create and manipulate those data structures, the IndexData and VertexData classes provide
 *  a simple way to do just that. The data is stored sequentially (one vertex or index after
 *  the other) so that it can easily be uploaded to a buffer.</p>
 *
 *  <strong>Vertex Format</strong>
 *
 *  <p>The VertexData class requires a custom format string on initialization, or an instance
 *  of the VertexDataFormat class. Here is an example:</p>
 *
 *  <listing>
 *  vertexData = new VertexData("position:float2, color:bytes4");
 *  vertexData.setPoint(0, "position", 320, 480);
 *  vertexData.setColor(0, "color", 0xff00ff);</listing>
 *
 *  <p>This instance is set up with two attributes: "position" and "color". The keywords
 *  after the colons depict the format and size of the data that each property uses; in this
 *  case, we store two floats for the position (for the x- and y-coordinates) and four
 *  bytes for the color. Please refer to the VertexDataFormat documentation for details.</p>
 *
 *  <p>The attribute names are then used to read and write data to the respective positions
 *  inside a vertex. Furthermore, they come in handy when copying data from one VertexData
 *  instance to another: attributes with equal name and data format may be transferred between
 *  different VertexData objects, even when they contain different sets of attributes or have
 *  a different layout.</p>
 *
 *  <strong>Colors</strong>
 *
 *  <p>Always use the format <code>bytes4</code> for color data. The color access methods
 *  expect that format, since it's the most efficient way to store color data. Furthermore,
 *  you should always include the string "color" (or "Color") in the name of color data;
 *  that way, it will be recognized as such and will always have its value pre-filled with
 *  pure white at full opacity.</p>
 *
 *  <strong>Premultiplied Alpha</strong>
 *
 *  <p>Per default, color values are stored with premultiplied alpha values, which
 *  means that the <code>rgb</code> values were multiplied with the <code>alpha</code> values
 *  before saving them. You can change this behavior with the <code>premultipliedAlpha</code>
 *  property.</p>
 *
 *  <p>Beware: with premultiplied alpha, the alpha value always affects the resolution of
 *  the RGB channels. A small alpha value results in a lower accuracy of the other channels,
 *  and if the alpha value reaches zero, the color information is lost altogether.</p>
 *
 *  <strong>Tinting</strong>
 *
 *  <p>Some low-end hardware is very sensitive when it comes to fragment shader complexity.
 *  Thus, Starling optimizes shaders for non-tinted meshes. The VertexData class keeps track
 *  of its <code>tinted</code>-state, at least at a basic level: whenever you change color
 *  or alpha value of a vertex to something different than white (<code>0xffffff</code>) with
 *  full alpha (<code>1.0</code>), the <code>tinted</code> property is enabled.</p>
 *
 *  <p>However, that value is not entirely accurate: when you restore the color of just a
 *  range of vertices, or copy just a subset of vertices to another instance, the property
 *  might wrongfully indicate a tinted mesh. If that's the case, you can either call
 *  <code>updateTinted()</code> or assign a custom value to the <code>tinted</code>-property.
 *  </p>
 *
 *  @see VertexDataFormat
 *  @see IndexData
 */
public class VertexData {
    private var _rawData:FastByteArray;
    private var _heapOffset:uint;

    private var _numVertices:int;
    private var _format:VertexDataFormat;
    private var _attributes:Vector.<VertexDataAttribute>;
    private var _numAttributes:int;
    private var _premultipliedAlpha:Boolean;
    private var _tinted:Boolean;

    private var _posOffset:int;  // in bytes
    private var _colOffset:int;  // in bytes
    private var _vertexSize:int; // in bytes

    // helper objects
    private static var sHelperPoint:Point = new Point();
    private static var sHelperPoint3D:Vector3D = new Vector3D();
    private static var sBytes:FastByteArray = FastByteArray.create(4);

    /** Creates an empty VertexData object with the given format and initial capacity.
     *
     *  @param format
     *
     *  Either a VertexDataFormat instance or a String that describes the data format.
     *  Refer to the VertexDataFormat class for more information. If you don't pass a format,
     *  the default <code>MeshStyle.VERTEX_FORMAT</code> will be used.
     *
     *  @param initialCapacity
     *
     *  The initial capacity affects just the way the internal ByteArray is allocated, not the
     *  <code>numIndices</code> value, which will always be zero when the constructor returns.
     *  The reason for this behavior is the peculiar way in which ByteArrays organize their
     *  memory:
     *
     *  <p>The first time you set the length of a ByteArray, it will adhere to that:
     *  a ByteArray with length 20 will take up 20 bytes (plus some overhead). When you change
     *  it to a smaller length, it will stick to the original value, e.g. with a length of 10
     *  it will still take up 20 bytes. However, now comes the weird part: change it to
     *  anything above the original length, and it will allocate 4096 bytes!</p>
     *
     *  <p>Thus, be sure to always make a generous educated guess, depending on the planned
     *  usage of your VertexData instances.</p>
     */
    public function VertexData(format:* = null, initialCapacity:int = 32) {
        if (format == null) _format = MeshStyle.VERTEX_FORMAT;
        else if (format is VertexDataFormat) _format = format;
        else if (format is String) _format = VertexDataFormat.fromString(format as String);
        else throw new ArgumentError("'format' must be String or VertexDataFormat");

        _attributes = _format.attributes;
        _numAttributes = _attributes.length;
        _posOffset = _format.hasAttribute("position") ? _format.getOffset("position") : 0;
        _colOffset = _format.hasAttribute("color") ? _format.getOffset("color") : 0;
        _vertexSize = _format.vertexSize;
        _numVertices = 0;
        _premultipliedAlpha = true;

        _rawData = FastByteArray.create(initialCapacity * _vertexSize);
        _rawData.length = 0; // changes length, but not memory!
        _heapOffset = _rawData.offset;
    }

    /** Explicitly frees up the memory used by the ByteArray. */
    public function clear():void {
        if (_rawData) {
            _rawData.dispose();
            _rawData = null;
        }
        _numVertices = 0;
        _tinted = false;
    }

    /** Creates a duplicate of the vertex data object. */
    public function clone():VertexData {
        var clone:VertexData = new VertexData(_format, _numVertices);
        writeBytes(clone._rawData, _rawData, 0, _rawData.length);
        clone._heapOffset = clone._rawData.offset;
        clone._numVertices = _numVertices;
        clone._premultipliedAlpha = _premultipliedAlpha;
        clone._tinted = _tinted;
        return clone;
    }

    public function writeBytes(destinationFastBytes:FastByteArray, sourceFastBytes:FastByteArray, offset:uint = 0, length:uint = 0):void {
        length = length == 0 ? sourceFastBytes.length : length;
        var destinationEndPosition:int = destinationFastBytes.position + length;
        if (destinationFastBytes.length < destinationEndPosition) {
            destinationFastBytes.length = destinationEndPosition;
        }
        var heapAddress:uint = destinationFastBytes.getCurrentHeapAddress();
        var sourceHeapAddress:uint = sourceFastBytes.getHeapAddress(offset);

        var byteCount:int = length % 4;
        var sourceEndPosition:uint = sourceFastBytes.getHeapAddress(offset + byteCount);
        while (sourceHeapAddress < sourceEndPosition) {
            si8(li8(sourceHeapAddress++), heapAddress++);
        }
        sourceEndPosition = sourceFastBytes.getHeapAddress(offset + length);
        while (sourceHeapAddress < sourceEndPosition) {
            si32(li32(sourceHeapAddress), heapAddress);
            heapAddress += 4;
            sourceHeapAddress += 4;
        }
    }

    /** Copies the vertex data (or a range of it, defined by 'vertexID' and 'numVertices')
     *  of this instance to another vertex data object, starting at a certain target index.
     *  If the target is not big enough, it will be resized to fit all the new vertices.
     *
     *  <p>If you pass a non-null matrix, the 2D position of each vertex will be transformed
     *  by that matrix before storing it in the target object. (The position being either an
     *  attribute with the name "position" or, if such an attribute is not found, the first
     *  attribute of each vertex. It must consist of two float values containing the x- and
     *  y-coordinates of the vertex.)</p>
     *
     *  <p>Source and target do not need to have the exact same format. Only properties that
     *  exist in the target will be copied; others will be ignored. If a property with the
     *  same name but a different format exists in the target, an exception will be raised.
     *  Beware, though, that the copy-operation becomes much more expensive when the formats
     *  differ.</p>
     */
    public function copyTo(target:VertexData, targetVertexID:int = 0, matrix:Matrix = null,
                           vertexID:int = 0, numVertices:int = -1):void {
        if (target == null) {
            BugTrackerDataProvider.globalError.targetIsNull = true;
        }
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        if (_format === target._format) {
            if (target._numVertices < targetVertexID + numVertices)
                target._numVertices = targetVertexID + numVertices;

            target._tinted ||= _tinted;

            // In this case, it's fastest to copy the complete range in one call
            // and then overwrite only the transformed positions.

            var targetRawData:FastByteArray = target._rawData;
            if (targetRawData == null) {
                BugTrackerDataProvider.globalError.targetRawDataIsNull = true;
            }
            targetRawData.position = targetVertexID * _vertexSize;
            writeBytes(targetRawData, _rawData, ( vertexID * _vertexSize), numVertices * _vertexSize);
            target._heapOffset = targetRawData.offset;
            if (matrix) {
                var x:Number, y:Number;
                var heapAddress:uint = targetRawData.offset + targetVertexID * _vertexSize + _posOffset;
                var endAddress:uint = heapAddress + (numVertices * _vertexSize);

                while (heapAddress < endAddress) {
                    x = lf32(heapAddress);
                    y = lf32(heapAddress + 4);

                    sf32(matrix.a * x + matrix.c * y + matrix.tx, heapAddress);
                    sf32(matrix.d * y + matrix.b * x + matrix.ty, heapAddress + 4);
                    heapAddress += _vertexSize;
                }
            }
        }
        else {
            if (target._numVertices < targetVertexID + numVertices)
                target.numVertices = targetVertexID + numVertices; // ensure correct alphas!

            for (var i:int = 0; i < _numAttributes; ++i) {
                var srcAttr:VertexDataAttribute = _attributes[i];
                var tgtAttr:VertexDataAttribute = target.getAttribute(srcAttr.name);

                if (tgtAttr) // only copy attributes that exist in the target, as well
                {
                    if (srcAttr.offset == _posOffset)
                        copyAttributeTo_internal(target, targetVertexID, matrix,
                                srcAttr, tgtAttr, vertexID, numVertices);
                    else
                        copyAttributeTo_internal(target, targetVertexID, null,
                                srcAttr, tgtAttr, vertexID, numVertices);
                }
            }
        }
    }

    /** Copies a specific attribute of all contained vertices (or a range of them, defined by
     *  'vertexID' and 'numVertices') to another VertexData instance. Beware that both name
     *  and format of the attribute must be identical in source and target.
     *  If the target is not big enough, it will be resized to fit all the new vertices.
     *
     *  <p>If you pass a non-null matrix, the specified attribute will be transformed by
     *  that matrix before storing it in the target object. It must consist of two float
     *  values.</p>
     */
    public function copyAttributeTo(target:VertexData, targetVertexID:int, attrName:String,
                                    matrix:Matrix = null, vertexID:int = 0, numVertices:int = -1):void {
        var sourceAttribute:VertexDataAttribute = getAttribute(attrName);
        var targetAttribute:VertexDataAttribute = target.getAttribute(attrName);

        if (sourceAttribute == null)
            throw new ArgumentError("Attribute '" + attrName + "' not found in source data");

        if (targetAttribute == null)
            throw new ArgumentError("Attribute '" + attrName + "' not found in target data");

        if (sourceAttribute.isColor)
            target._tinted ||= _tinted;

        copyAttributeTo_internal(target, targetVertexID, matrix,
                sourceAttribute, targetAttribute, vertexID, numVertices);
    }

    private function copyAttributeTo_internal(target:VertexData, targetVertexID:int, matrix:Matrix,
                                              sourceAttribute:VertexDataAttribute, targetAttribute:VertexDataAttribute,
                                              vertexID:int, numVertices:int):void {
        if (sourceAttribute.format != targetAttribute.format)
            throw new IllegalOperationError("Attribute formats differ between source and target");

        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        if (target._numVertices < targetVertexID + numVertices)
            target._numVertices = targetVertexID + numVertices;

        var i:int, j:int, x:Number, y:Number;
        var sourceData:FastByteArray = _rawData;
        var sourceDataHeapOffset:uint = sourceData.offset;
        var sourceDelta:int = _vertexSize - sourceAttribute.size;
        var targetDelta:int = target._vertexSize - targetAttribute.size;
        var attributeSizeIn32Bits:int = sourceAttribute.size / 4;

        var sourceHeapAddress:uint = sourceDataHeapOffset + vertexID * _vertexSize + sourceAttribute.offset;
        var targetHeapAddress:uint = sourceDataHeapOffset + targetVertexID * target._vertexSize + targetAttribute.offset;
        if (matrix) {
            for (i = 0; i < numVertices; ++i) {
                x = lf32(sourceHeapAddress);
                y = lf32(sourceHeapAddress += 4);
                sf32(matrix.a * x + matrix.c * y + matrix.tx, sourceHeapAddress += 4);
                sf32(matrix.d * y + matrix.b * x + matrix.ty, sourceHeapAddress += 4);

                sourceHeapAddress += sourceDelta;
                targetHeapAddress += targetDelta;
            }
        }
        else {
            for (i = 0; i < numVertices; ++i) {
                for (j = 0; j < attributeSizeIn32Bits; ++j) {
                    si32(li32(sourceHeapAddress), targetHeapAddress);
                    sourceHeapAddress += 4;
                    targetHeapAddress += 4;
                }


                sourceHeapAddress += sourceDelta;
                targetHeapAddress += targetDelta;
            }
        }
    }

    /** Optimizes the ByteArray so that it has exactly the required capacity, without
     *  wasting any memory. If your VertexData object grows larger than the initial capacity
     *  you passed to the constructor, call this method to avoid the 4k memory problem. */
    public function trim():void {
        var numBytes:int = _numVertices * _vertexSize;

        sBytes.length = numBytes;
        sBytes.position = 0;
        writeBytes(sBytes, _rawData, 0, numBytes);

        FastByteArray.switchMemory(_rawData, sBytes);
        _heapOffset = _rawData.offset;

        sBytes.clear();
    }

    /** Returns a string representation of the VertexData object,
     *  describing both its format and size. */
    public function toString():String {
        return StringUtil.format("[VertexData format=\"{0}\" numVertices={1}]",
                _format.formatString, _numVertices);
    }

    // read / write attributes

    /** Reads an unsigned integer value from the specified vertex and attribute. */
    public function getUnsignedInt(vertexID:int, attrName:String):uint {
        return li32(_heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset);
    }

    /** Writes an unsigned integer value to the specified vertex and attribute. */
    public function setUnsignedInt(vertexID:int, attrName:String, value:uint):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;
        si32(value, _heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset);

    }

    /** Reads a float value from the specified vertex and attribute. */
    public function getFloat(vertexID:int, attrName:String):Number {
        return lf32(_heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset);
    }

    /** Writes a float value to the specified vertex and attribute. */
    public function setFloat(vertexID:int, attrName:String, value:Number):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;
        sf32(value, _heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset);
    }

    /** Reads a Point from the specified vertex and attribute. */
    public function getPoint(vertexID:int, attrName:String, out:Point = null):Point {
        if (out == null) out = new Point();

        var offset:int = attrName == "position" ? _posOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        out.x = lf32(heapAddress);
        out.y = lf32(heapAddress + 4);
        return out;
    }

    /** Writes the given coordinates to the specified vertex and attribute. */
    public function setPoint(vertexID:int, attrName:String, x:Number, y:Number):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;

        var offset:int = attrName == "position" ? _posOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        sf32(x, heapAddress);
        sf32(y, heapAddress + 4);
    }

    /** Reads a Vector3D from the specified vertex and attribute.
     *  The 'w' property of the Vector3D is ignored. */
    public function getPoint3D(vertexID:int, attrName:String, out:Vector3D = null):Vector3D {
        if (out == null) out = new Vector3D();

        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset;
        out.x = lf32(heapAddress);
        out.y = lf32(heapAddress + 4);
        out.z = lf32(heapAddress + 8);
        return out;
    }

    /** Writes the given coordinates to the specified vertex and attribute. */
    public function setPoint3D(vertexID:int, attrName:String, x:Number, y:Number, z:Number):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;

        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset;
        sf32(x, heapAddress);
        sf32(y, heapAddress + 4);
        sf32(z, heapAddress + 8);
    }

    /** Reads a Vector3D from the specified vertex and attribute, including the fourth
     *  coordinate ('w'). */
    public function getPoint4D(vertexID:int, attrName:String, out:Vector3D = null):Vector3D {
        if (out == null) out = new Vector3D();

        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset;
        out.x = lf32(heapAddress);
        out.y = lf32(heapAddress + 4);
        out.z = lf32(heapAddress + 8);
        out.w = lf32(heapAddress + 12);
        return out;
    }

    /** Writes the given coordinates to the specified vertex and attribute. */
    public function setPoint4D(vertexID:int, attrName:String,
                               x:Number, y:Number, z:Number, w:Number = 1.0):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;

        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + getAttribute(attrName).offset;
        sf32(x, heapAddress);
        sf32(y, heapAddress + 4);
        sf32(z, heapAddress + 8);
        sf32(w, heapAddress + 12);
    }

    /** Reads an RGB color from the specified vertex and attribute (no alpha). */
    public function getColor(vertexID:int, attrName:String = "color"):uint {
        var offset:int = attrName == "color" ? _colOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        var rgba:uint = switchEndian(li32(heapAddress));
        if (_premultipliedAlpha) rgba = unmultiplyAlpha(rgba);
        return (rgba >> 8) & 0xffffff;
    }

    /** Writes the RGB color to the specified vertex and attribute (alpha is not changed). */
    public function setColor(vertexID:int, attrName:String, color:uint):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;

        var alpha:Number = getAlpha(vertexID, attrName);
        colorize(attrName, color, alpha, vertexID, 1);
    }

    /** Reads the alpha value from the specified vertex and attribute. */
    public function getAlpha(vertexID:int, attrName:String = "color"):Number {
        var offset:int = attrName == "color" ? _colOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        var rgba:uint = switchEndian(li32(heapAddress));
        return (rgba & 0xff) / 255.0;
    }

    /** Writes the given alpha value to the specified vertex and attribute (range 0-1). */
    public function setAlpha(vertexID:int, attrName:String, alpha:Number):void {
        if (_numVertices < vertexID + 1)
            numVertices = vertexID + 1;

        var color:uint = getColor(vertexID, attrName);
        colorize(attrName, color, alpha, vertexID, 1);
    }

    // bounds helpers

    /** Calculates the bounds of the 2D vertex positions identified by the given name.
     *  The positions may optionally be transformed by a matrix before calculating the bounds.
     *  If you pass an 'out' Rectangle, the result will be stored in this rectangle
     *  instead of creating a new object. To use all vertices for the calculation, set
     *  'numVertices' to '-1'. */
    public function getBounds(attrName:String = "position", matrix:Matrix = null,
                              vertexID:int = 0, numVertices:int = -1, out:Rectangle = null):Rectangle {
        if (out == null) out = new Rectangle();
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        if (numVertices == 0) {
            if (matrix == null)
                out.setEmpty();
            else {
                MatrixUtil.transformCoords(matrix, 0, 0, sHelperPoint);
                out.setTo(sHelperPoint.x, sHelperPoint.y, 0, 0);
            }
        }
        else {
            var minX:Number = Number.MAX_VALUE, maxX:Number = -Number.MAX_VALUE;
            var minY:Number = Number.MAX_VALUE, maxY:Number = -Number.MAX_VALUE;
            var offset:int = attrName == "position" ? _posOffset : getAttribute(attrName).offset;
            var x:Number, y:Number, i:int;
            var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
            if (matrix == null) {
                for (i = 0; i < numVertices; ++i) {
                    x = lf32(heapAddress);
                    y = lf32(heapAddress + 4);
                    heapAddress += _vertexSize;

                    if (minX > x) minX = x;
                    if (maxX < x) maxX = x;
                    if (minY > y) minY = y;
                    if (maxY < y) maxY = y;
                }
            }
            else {
                for (i = 0; i < numVertices; ++i) {
                    x = lf32(heapAddress);
                    y = lf32(heapAddress + 4);
                    heapAddress += _vertexSize;

                    MatrixUtil.transformCoords(matrix, x, y, sHelperPoint);

                    if (minX > sHelperPoint.x) minX = sHelperPoint.x;
                    if (maxX < sHelperPoint.x) maxX = sHelperPoint.x;
                    if (minY > sHelperPoint.y) minY = sHelperPoint.y;
                    if (maxY < sHelperPoint.y) maxY = sHelperPoint.y;
                }
            }

            out.setTo(minX, minY, maxX - minX, maxY - minY);
        }

        return out;
    }

    /** Calculates the bounds of the 2D vertex positions identified by the given name,
     *  projected into the XY-plane of a certain 3D space as they appear from the given
     *  camera position. Note that 'camPos' is expected in the target coordinate system
     *  (the same that the XY-plane lies in).
     *
     *  <p>If you pass an 'out' Rectangle, the result will be stored in this rectangle
     *  instead of creating a new object. To use all vertices for the calculation, set
     *  'numVertices' to '-1'.</p> */
    public function getBoundsProjected(attrName:String, matrix:Matrix3D,
                                       camPos:Vector3D, vertexID:int = 0, numVertices:int = -1,
                                       out:Rectangle = null):Rectangle {
        if (out == null) out = new Rectangle();
        if (camPos == null) throw new ArgumentError("camPos must not be null");
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        if (numVertices == 0) {
            if (matrix)
                MatrixUtil.transformCoords3D(matrix, 0, 0, 0, sHelperPoint3D);
            else
                sHelperPoint3D.setTo(0, 0, 0);

            MathUtil.intersectLineWithXYPlane(camPos, sHelperPoint3D, sHelperPoint);
            out.setTo(sHelperPoint.x, sHelperPoint.y, 0, 0);
        }
        else {
            var minX:Number = Number.MAX_VALUE, maxX:Number = -Number.MAX_VALUE;
            var minY:Number = Number.MAX_VALUE, maxY:Number = -Number.MAX_VALUE;
            var offset:int = attrName == "position" ? _posOffset : getAttribute(attrName).offset;
            var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
            var x:Number, y:Number, i:int;

            for (i = 0; i < numVertices; ++i) {
                x = lf32(heapAddress);
                y = lf32(heapAddress + 4);
                heapAddress += _vertexSize;

                if (matrix)
                    MatrixUtil.transformCoords3D(matrix, x, y, 0, sHelperPoint3D);
                else
                    sHelperPoint3D.setTo(x, y, 0);

                MathUtil.intersectLineWithXYPlane(camPos, sHelperPoint3D, sHelperPoint);

                if (minX > sHelperPoint.x) minX = sHelperPoint.x;
                if (maxX < sHelperPoint.x) maxX = sHelperPoint.x;
                if (minY > sHelperPoint.y) minY = sHelperPoint.y;
                if (maxY < sHelperPoint.y) maxY = sHelperPoint.y;
            }

            out.setTo(minX, minY, maxX - minX, maxY - minY);
        }

        return out;
    }

    /** Indicates if color attributes should be stored premultiplied with the alpha value.
     *  Changing this value does <strong>not</strong> modify any existing color data.
     *  If you want that, use the <code>setPremultipliedAlpha</code> method instead.
     *  @default true */
    public function get premultipliedAlpha():Boolean {
        return _premultipliedAlpha;
    }

    public function set premultipliedAlpha(value:Boolean):void {
        setPremultipliedAlpha(value, false);
    }

    /** Changes the way alpha and color values are stored. Optionally updates all existing
     *  vertices. */
    public function setPremultipliedAlpha(value:Boolean, updateData:Boolean):void {
        if (updateData && value != _premultipliedAlpha) {
            for (var i:int = 0; i < _numAttributes; ++i) {
                var attribute:VertexDataAttribute = _attributes[i];
                if (attribute.isColor) {
                    var heapAddress:uint = _heapOffset + attribute.offset;
                    var oldColor:uint;
                    var newColor:uint;

                    for (var j:int = 0; j < _numVertices; ++j) {
                        oldColor = switchEndian(li32(heapAddress));
                        newColor = value ? switchEndian(premultiplyAlpha(oldColor)) : switchEndian(unmultiplyAlpha(oldColor));
                        si32(newColor, heapAddress);
                        heapAddress += _vertexSize;
                    }
                }
            }
        }

        _premultipliedAlpha = value;
    }

    /** Updates the <code>tinted</code> property from the actual color data. This might make
     *  sense after copying part of a tinted VertexData instance to another, since not each
     *  color value is checked in the process. An instance is tinted if any vertices have a
     *  non-white color or are not fully opaque. */
    public function updateTinted(attrName:String = "color"):Boolean {
        var heapAddress:uint = attrName == "color" ? _heapOffset + _colOffset : _heapOffset + getAttribute(attrName).offset;
        _tinted = false;

        for (var i:int = 0; i < _numVertices; ++i) {
            if (li32(heapAddress) != 0xffffffff) {
                _tinted = true;
                break;
            }
            heapAddress += _vertexSize;
        }

        return _tinted;
    }

    // modify multiple attributes

    /** Transforms the 2D positions of subsequent vertices by multiplication with a
     *  transformation matrix. */
    public function transformPoints(attrName:String, matrix:Matrix,
                                    vertexID:int = 0, numVertices:int = -1):void {
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        var x:Number, y:Number;
        var offset:int = attrName == "position" ? _posOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        var endAddress:uint = heapAddress + numVertices * _vertexSize;

        while (heapAddress < endAddress) {
            x = lf32(heapAddress);
            y = lf32(heapAddress + 4);
            sf32(matrix.a * x + matrix.c * y + matrix.tx, heapAddress);
            sf32(matrix.d * y + matrix.b * x + matrix.ty, heapAddress + 4);
            heapAddress += _vertexSize;
        }
    }

    /** Translates the 2D positions of subsequent vertices by a certain offset. */
    public function translatePoints(attrName:String, deltaX:Number, deltaY:Number,
                                    vertexID:int = 0, numVertices:int = -1):void {
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        var x:Number, y:Number;
        var offset:int = attrName == "position" ? _posOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        var endAddress:uint = heapAddress + numVertices * _vertexSize;

        while (heapAddress < endAddress) {
            x = lf32(heapAddress);
            y = lf32(heapAddress + 4);

            sf32(x + deltaX, heapAddress);
            sf32(y + deltaY, heapAddress + 4);
            heapAddress += _vertexSize;
        }
    }

    /** Multiplies the alpha values of subsequent vertices by a certain factor. */
    public function scaleAlphas(attrName:String, factor:Number,
                                vertexID:int = 0, numVertices:int = -1):void {
        if (factor == 1.0) return;
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        _tinted = true; // factor must be != 1, so there's definitely tinting.

        var i:int;
        var offset:int = attrName == "color" ? _colOffset : getAttribute(attrName).offset;
        var colorAddress:uint = _heapOffset + vertexID * _vertexSize + offset;

        for (i = 0; i < numVertices; ++i) {
            var alphaAddress:uint = colorAddress + 3;
            var alpha:Number = li8(alphaAddress) / 255.0 * factor;

            if (alpha > 1.0) alpha = 1.0;
            else if (alpha < 0.0) alpha = 0.0;

            if (alpha == 1.0 || !_premultipliedAlpha) {
                var value:int = int(alpha * 255.0);
                si8(value, alphaAddress);
            }
            else {
                var rgba:uint = unmultiplyAlpha(switchEndian(li32(colorAddress)));
                rgba = (rgba & 0xffffff00) | (int(alpha * 255.0) & 0xff);
                rgba = switchEndian(premultiplyAlpha(rgba));

                si32(rgba, colorAddress);
            }

            colorAddress += _vertexSize;
        }
    }

    /** Writes the given RGB and alpha values to the specified vertices. */
    public function colorize(attrName:String = "color", color:uint = 0xffffff, alpha:Number = 1.0,
                             vertexID:int = 0, numVertices:int = -1):void {
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        var offset:int = attrName == "color" ? _colOffset : getAttribute(attrName).offset;
        var heapAddress:uint = _heapOffset + vertexID * _vertexSize + offset;
        var endAddress:uint = heapAddress + numVertices * _vertexSize;

        if (alpha > 1.0) alpha = 1.0;
        else if (alpha < 0.0) alpha = 0.0;

        var rgba:uint = ((color << 8) & 0xffffff00) | (int(alpha * 255.0) & 0xff);

        if (rgba == 0xffffffff && numVertices == _numVertices) _tinted = false;
        else if (rgba != 0xffffffff) _tinted = true;

        rgba = (_premultipliedAlpha && alpha != 1.0) ? switchEndian(premultiplyAlpha(rgba)) : switchEndian(rgba);

        si32(rgba, heapAddress);
        while (heapAddress < endAddress) {
            si32(rgba, heapAddress);
            heapAddress += _vertexSize;
        }
    }

    // format helpers

    /** Returns the format of a certain vertex attribute, identified by its name.
     * Typical values: <code>float1, float2, float3, float4, bytes4</code>. */
    public function getFormat(attrName:String):String {
        return getAttribute(attrName).format;
    }

    /** Returns the size of a certain vertex attribute in bytes. */
    public function getSize(attrName:String):int {
        return getAttribute(attrName).size;
    }

    /** Returns the size of a certain vertex attribute in 32 bit units. */
    public function getSizeIn32Bits(attrName:String):int {
        return getAttribute(attrName).size / 4;
    }

    /** Returns the offset (in bytes) of an attribute within a vertex. */
    public function getOffset(attrName:String):int {
        return getAttribute(attrName).offset;
    }

    /** Returns the offset (in 32 bit units) of an attribute within a vertex. */
    public function getOffsetIn32Bits(attrName:String):int {
        return getAttribute(attrName).offset / 4;
    }

    /** Indicates if the VertexData instances contains an attribute with the specified name. */
    public function hasAttribute(attrName:String):Boolean {
        return getAttribute(attrName) != null;
    }

    // VertexBuffer helpers

    /** Creates a vertex buffer object with the right size to fit the complete data.
     *  Optionally, the current data is uploaded right away. */
    public function createVertexBuffer(upload:Boolean = false,
                                       bufferUsage:String = "staticDraw"):VertexBuffer3D {
        var context:Context3D = Starling.context;
        if (context == null) throw new MissingContextError();
        if (_numVertices == 0) return null;

        var buffer:VertexBuffer3D = context.createVertexBuffer(
                _numVertices, _vertexSize / 4, bufferUsage);

        if (upload) uploadToVertexBuffer(buffer);
        return buffer;
    }

    /** Uploads the complete data (or a section of it) to the given vertex buffer. */
    public function uploadToVertexBuffer(buffer:VertexBuffer3D, vertexID:int = 0, numVertices:int = -1):void {
        if (numVertices < 0 || vertexID + numVertices > _numVertices)
            numVertices = _numVertices - vertexID;

        if (numVertices > 0)
            buffer.uploadFromByteArray(_rawData.heap, _rawData.offset, vertexID, numVertices);
    }

    [Inline]
    private final function getAttribute(attrName:String):VertexDataAttribute {
        var i:int, attribute:VertexDataAttribute;

        for (i = 0; i < _numAttributes; ++i) {
            attribute = _attributes[i];
            if (attribute.name == attrName) return attribute;
        }

        return null;
    }

    [Inline]
    private static function switchEndian(value:uint):uint {
        return ( value & 0xff) << 24 |
                ((value >> 8) & 0xff) << 16 |
                ((value >> 16) & 0xff) << 8 |
                ((value >> 24) & 0xff);
    }

    private static function premultiplyAlpha(rgba:uint):uint {
        var alpha:uint = rgba & 0xff;

        if (alpha == 0xff) return rgba;
        else {
            var factor:Number = alpha / 255.0;
            var r:uint = ((rgba >> 24) & 0xff) * factor;
            var g:uint = ((rgba >> 16) & 0xff) * factor;
            var b:uint = ((rgba >> 8) & 0xff) * factor;

            return (r & 0xff) << 24 |
                    (g & 0xff) << 16 |
                    (b & 0xff) << 8 | alpha;
        }
    }

    private static function unmultiplyAlpha(rgba:uint):uint {
        var alpha:uint = rgba & 0xff;

        if (alpha == 0xff || alpha == 0x0) return rgba;
        else {
            var factor:Number = alpha / 255.0;
            var r:uint = ((rgba >> 24) & 0xff) / factor;
            var g:uint = ((rgba >> 16) & 0xff) / factor;
            var b:uint = ((rgba >> 8) & 0xff) / factor;

            return (r & 0xff) << 24 |
                    (g & 0xff) << 16 |
                    (b & 0xff) << 8 | alpha;
        }
    }

    // properties

    /** The total number of vertices. If you make the object bigger, it will be filled up with
     *  <code>1.0</code> for all alpha values and zero for everything else. */
    public function get numVertices():int {
        return _numVertices;
    }

    public function set numVertices(value:int):void {
        if (value > _numVertices) {
            var oldLength:int = _numVertices * vertexSize;
            var newLength:int = value * _vertexSize;
            var heapAddress:uint;

            if (_rawData.length > oldLength) {
                heapAddress = _heapOffset + oldLength;
                var rawDataLength:uint = _rawData.length;
                while (heapAddress < rawDataLength) {
                    si32(0, heapAddress);
                    heapAddress += 4;
                }
            }

            if (_rawData.length < newLength) {
                _rawData.length = newLength;
                _heapOffset = _rawData.offset;
            }

            for (var i:int = 0; i < _numAttributes; ++i) {
                var attribute:VertexDataAttribute = _attributes[i];
                if (attribute.isColor) // initialize color values with "white" and full alpha
                {
                    heapAddress = _heapOffset + _numVertices * _vertexSize + attribute.offset;
                    for (var j:int = _numVertices; j < value; ++j) {
                        si32(0xffffffff, heapAddress);
                        heapAddress += _vertexSize;
                    }
                }
            }
        }

        if (value == 0) _tinted = false;
        _numVertices = value;
    }

    /** The format that describes the attributes of each vertex.
     *  When you assign a different format, the raw data will be converted accordingly,
     *  i.e. attributes with the same name will still point to the same data.
     *  New properties will be filled up with zeros (except for colors, which will be
     *  initialized with an alpha value of 1.0). As a side-effect, the instance will also
     *  be trimmed. */
    public function get format():VertexDataFormat {
        return _format;
    }

    public function set format(value:VertexDataFormat):void {
        if (_format === value) return;

        var a:int, i:int;
        var srcVertexSize:int = _format.vertexSize;
        var tgtVertexSize:int = value.vertexSize;
        var numAttributes:int = value.numAttributes;

        sBytes.length = value.vertexSize * _numVertices;
        var heapOffset:uint = sBytes.offset;

        for (a = 0; a < numAttributes; ++a) {
            var tgtAttr:VertexDataAttribute = value.attributes[a];
            var srcAttr:VertexDataAttribute = getAttribute(tgtAttr.name);

            if (srcAttr) // copy attributes that exist in both targets
            {
                sBytes.position = tgtAttr.offset;
                for (i = 0; i < _numVertices; ++i) {
                    writeBytes(sBytes, _rawData, (srcVertexSize * i + srcAttr.offset), srcAttr.size);
                    sBytes.position += tgtVertexSize;
                }
            }
            else if (tgtAttr.isColor) // initialize color values with "white" and full alpha
            {
                var heapAddress:uint = heapOffset + tgtAttr.offset;
                for (i = 0; i < _numVertices; ++i) {
                    si32(0xffffffff, heapAddress);
                    heapAddress += tgtVertexSize;
                }
            }
        }
        FastByteArray.switchMemory(_rawData, sBytes);
        _heapOffset = _rawData.offset;

        _format = value;
        _attributes = _format.attributes;
        _numAttributes = _attributes.length;
        _vertexSize = _format.vertexSize;
        _posOffset = _format.hasAttribute("position") ? _format.getOffset("position") : 0;
        _colOffset = _format.hasAttribute("color") ? _format.getOffset("color") : 0;
    }

    /** Indicates if the mesh contains any vertices that are not white or not fully opaque.
     *  If <code>false</code> (and the value wasn't modified manually), the result is 100%
     *  accurate; <code>true</code> represents just an educated guess. To be entirely sure,
     *  you may call <code>updateTinted()</code>.
     */
    public function get tinted():Boolean {
        return _tinted;
    }

    public function set tinted(value:Boolean):void {
        _tinted = value;
    }

    /** The format string that describes the attributes of each vertex. */
    public function get formatString():String {
        return _format.formatString;
    }

    /** The size (in bytes) of each vertex. */
    public function get vertexSize():int {
        return _vertexSize;
    }

    /** The size (in 32 bit units) of each vertex. */
    public function get vertexSizeIn32Bits():int {
        return _vertexSize / 4.0;
    }

    /** The size (in bytes) of the raw vertex data. */
    public function get size():int {
        return _numVertices * _vertexSize;
    }

    /** The size (in 32 bit units) of the raw vertex data. */
    public function get sizeIn32Bits():int {
        return _numVertices * _vertexSize / 4.0;
    }
}
}
