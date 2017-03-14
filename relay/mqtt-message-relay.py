import paho.mqtt.client as mqtt
import sys

gateways = dict()

def on_connect(_mqttc, obj, flags, status):
    print("connected: status=%s" % (status))
    return

def on_publish(_mqttc, obj, mid):
    print("mid: " + str(mid))
    return

def on_subscribe(_mqttc, obj, mid, granted_qos):
    print("Subscribed: " + str(mid) + " " + str(granted_qos))
    return

def on_log(_mqttc, obj, level, string):
    print(string)
    return

def on_message(_mqttc, obj, msg):
    url = msg.topic.split('/')
    print('URL: '+str(url))
    print('MSG: '+str(msg.payload))
    typeId = url[2]
    deviceId = url[4]
    event = url[6]
    msg_format = url[8]

    if typeId not in device_types:
        #print('Unhandled typeId ' + typeId)
        #print('Available device_types: ' + str(device_types))
        return

    if event == 'ping':
        hostname = msg.payload.decode("utf-8")
        if typeId not in gateways.keys():
            gateways[typeId] = {deviceId: hostname}
        if typeId in gateways.keys():
            if deviceId not in gateways[typeId]:
                gws = gateways[typeId]
                gws[deviceId] = hostname
                gateways[typeId] = gws
            print(list(gateways[typeId].keys()))
            for gw in list(gateways[typeId].keys()):
                topic = 'iot-2/type/'+typeId+'/id/'+gw+'/cmd/ping_update/fmt/'+msg_format
                gw_list_msg = "&".join(gateways[typeId].keys())
                hn_list_msg = "&".join(gateways[typeId].values())
                return_msg = gw_list_msg+':'+hn_list_msg
                print('Sending ping update to: '+str(gw)+' '+return_msg)
                _mqttc.publish(topic, return_msg)
            return

    elif event != 'ping' and typeId in gateways.keys() and (event in gateways[typeId].keys() or event in gateways[typeId].values()):
        if event in gateways[typeId].keys():
            topic = 'iot-2/type/'+typeId+'/id/'+event+'/cmd/message/fmt/'+msg_format
            _mqttc.publish(topic, msg.payload)
            return
        else:
            for key in gateways[typeId].keys():
                if gateways[typeId][key] == event:
                    topic = 'iot-2/type/'+typeId+'/id/'+key+'/cmd/message/fmt/'+msg_format
                    _mqttc.publish(topic, msg.payload)
            return

    elif event != 'ping' and typeId in gateways.keys() and event not in gateways[typeId] and deviceId in gateways[typeId]:
        for gw in gateways[typeId]:
            if gw != deviceId:
                topic = 'iot-2/type/'+typeId+'/id/'+gw+'/cmd/'+event+'/fmt/'+msg_format
                _mqttc.publish(topic, msg.payload)
        return
    else:
        print('Unhandled')
    return

api_key = sys.argv[1]
auth_token = sys.argv[2]
org_id = sys.argv[3]
relay_id = sys.argv[4]

device_types = [relay_id]
#client_id = 'a:'+org_id+':'+relay_id
client_id = 'a:'+org_id+':12345'
host = org_id+'.messaging.internetofthings.ibmcloud.com'


mqttc = mqtt.Client(client_id)
mqttc.username_pw_set(api_key, password=auth_token)

mqttc.on_connect = on_connect
mqttc.on_subscribe = on_subscribe
mqttc.on_message = on_message

mqttc.connect(host=host, port=1883, keepalive=60)

mqttc.subscribe('iot-2/type/+/id/+/evt/+/fmt/+', 0)

mqttc.loop_forever()
